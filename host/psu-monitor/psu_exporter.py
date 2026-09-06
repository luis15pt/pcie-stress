#!/usr/bin/env python3
"""
Octoserver PSU Power Metrics Exporter
Universal PSU Power Metrics Prometheus Exporter for GPU Servers

Author: Luis Sarabando <luis.sarabando@nexgencloud.com>
Organization: NexGenCloud
Version: 1.0.0

Supports multiple motherboard models including:
- ASRockRack ROMED8-2T (3 PSUs)
- ASRockRack ROME2D32GM-2T (4 PSUs)
- Auto-detection for other configurations

Tested on:
- NVIDIA RTX 4090 systems
- NVIDIA RTX 5090 systems
- NVIDIA RTX A4000 systems
- Multiple motherboard manufacturers

Default port: 9175

Usage:
    python3 octoserver_psu_exporter.py [options]

Options:
    --port PORT          Port to listen on (default: 9175)
    --host HOST          Host to bind to (default: 0.0.0.0)
    --max-psus N         Maximum PSUs to check (default: 6, auto-detect)
    --model MODEL        Motherboard model (AUTO, ROMED8-2T, or ROME2D32GM-2T)
    --verbose            Show detailed PSU information
    --debug              Show debug information including raw data

Prometheus configuration:
  - job_name: 'psu_power'
    static_configs:
      - targets: ['your-server:9175']
    scrape_interval: 30s

Copyright (c) 2024 NexGenCloud
"""

import subprocess
import socket
import time
import sys
import argparse
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading
import json
import os

try:
    from prometheus_client import CollectorRegistry, Gauge, generate_latest, CONTENT_TYPE_LATEST
    from prometheus_client.core import GaugeMetricFamily, InfoMetricFamily
except ImportError as e:
    print(f"Error: prometheus_client package not installed. Install with: pip3 install prometheus-client")
    print(f"Import error: {e}")
    sys.exit(1)

# Global registry for metrics
REGISTRY = CollectorRegistry()

# Configuration
DEFAULT_PORT = 9175  # Octoserver PSU Exporter standard port
DEFAULT_HOST = '0.0.0.0'
MAX_PSU_ADDRESSES = 6  # Check up to 6 PSU slots by default
SUBPROCESS_TIMEOUT = 5  # Timeout for subprocess calls in seconds (prevents hanging)

# Version information
VERSION = "1.0.1"
AUTHOR = "Luis Sarabando"
CONTACT = "luis.sarabando@nexgencloud.com"

# Known motherboard configurations
MOTHERBOARD_CONFIGS = {
    'ROMED8-2T': {
        'expected_psus': 3,
        'bmc_mapping': {
            "PowerPSU0": "PSU1",    # 0xB0 -> PSU1
            "PowerPSU1": "PSU2",    # 0xB2 -> PSU2
            "PowerPSU2": "PSU3",    # 0xB4 -> PSU3 (may not be visible to BMC)
        },
        'temp_sensor_map': {
            "PowerPSU0": "PSU1 TEMP",
            "PowerPSU1": "PSU2 TEMP",
            "PowerPSU2": "PSU3 TEMP",
        }
    },
    'ROME2D32GM-2T': {
        'expected_psus': 4,
        'bmc_mapping': {
            "PowerPSU0": "PSU1",    # 0xB0 -> PSU1
            "PowerPSU1": "PSU2",    # 0xB2 -> PSU2
            "PowerPSU2": "none",    # 0xB4 -> Not visible to BMC
            "PowerPSU3": "none",    # 0xB6 -> Not visible to BMC
        },
        'temp_sensor_map': {
            "PowerPSU0": "TEMP_PSU1",
            "PowerPSU1": "TEMP_PSU2",
            "PowerPSU2": None,
            "PowerPSU3": None,
        }
    },
    'AUTO': {
        'expected_psus': None,  # Auto-detect
        'bmc_mapping': {},      # Will be populated based on detection
        'temp_sensor_map': {}   # Will be populated based on detection
    }
}


class PSUCollector:
    """Custom collector that gathers PSU metrics on each scrape"""
    
    def __init__(self, debug=False, verbose=False, max_psus=MAX_PSU_ADDRESSES, model='AUTO'):
        self.debug = debug
        self.verbose = verbose
        self.hostname = socket.gethostname()
        self.model = model
        self.config = MOTHERBOARD_CONFIGS.get(model, MOTHERBOARD_CONFIGS['AUTO'])
        
        if self.verbose:
            print(f"Octoserver PSU Power Metrics Exporter v{VERSION}")
            print(f"Author: {AUTHOR} <{CONTACT}>")
            print(f"Organization: NexGenCloud")
            print("-" * 50)
        
        # Candidate PMBus addresses. Different PSU vendors strap different
        # bases: GOSPOWER units sat at 0xB0/0xB2/0xB4 (step 2), SeaSonic at
        # 0xC0/0xC4 (step 4). Probe the whole 0xB0-0xCE range and keep whatever
        # actually answers, so a PSU swap does not silently blind the exporter.
        # Stops before 0xE0/0xE4: those answer 0x78 but are not PSUs.
        candidate_addrs = [0xB0 + (i * 2) for i in range(16)]

        self.psus = []
        for addr in candidate_addrs:
            if len(self.psus) >= max_psus:
                break
            a = f"0x{addr:02X}"
            if self.test_psu_presence(a):
                idx = len(self.psus)
                self.psus.append({
                    "name": f"PowerPSU{idx}",
                    "address": a,
                    "slot": str(idx)
                })
                if self.verbose:
                    print(f"Found PSU at {a} (PowerPSU{idx})")
        if self.verbose and not self.psus:
            print("No PSUs responded on any probed address (0xB0-0xCE)")
        if self.verbose:
            print(f"Total PSUs found: {len(self.psus)}")
            
        # Auto-detect motherboard model if not specified
        if model == 'AUTO':
            self.detect_motherboard_model()
        
        # Set up BMC mapping based on detected or specified model
        self.setup_bmc_mapping()
    
    def detect_motherboard_model(self):
        """Try to detect the motherboard model based on PSU count and other factors"""
        psu_count = len(self.psus)
        
        if psu_count == 3:
            self.model = 'ROMED8-2T'
            if self.verbose:
                print(f"Auto-detected motherboard: ROMED8-2T (3 PSUs found)")
        elif psu_count == 4:
            self.model = 'ROME2D32GM-2T'
            if self.verbose:
                print(f"Auto-detected motherboard: ROME2D32GM-2T (4 PSUs found)")
        else:
            # Try to detect from DMI information
            try:
                result = subprocess.run("dmidecode -s baseboard-product-name 2>/dev/null",
                                      shell=True, capture_output=True, text=True,
                                      timeout=SUBPROCESS_TIMEOUT)
                board_name = result.stdout.strip()
                if 'ROMED8-2T' in board_name:
                    self.model = 'ROMED8-2T'
                elif 'ROME2D32GM-2T' in board_name:
                    self.model = 'ROME2D32GM-2T'
                else:
                    self.model = 'GENERIC'
                    if self.verbose:
                        print(f"Unknown motherboard with {psu_count} PSUs, using generic config")
            except:
                self.model = 'GENERIC'
                if self.verbose:
                    print(f"Could not detect motherboard model, found {psu_count} PSUs")
    
    def setup_bmc_mapping(self):
        """Set up BMC sensor mapping based on detected model"""
        if self.model in MOTHERBOARD_CONFIGS:
            self.config = MOTHERBOARD_CONFIGS[self.model]
        else:
            # Generic configuration
            self.config = {
                'expected_psus': len(self.psus),
                'bmc_mapping': {},
                'temp_sensor_map': {}
            }
            
            # Try to detect BMC sensor names
            for psu in self.psus:
                slot_num = int(psu['slot']) + 1
                # Common sensor naming patterns
                self.config['bmc_mapping'][psu['name']] = f"PSU{slot_num}"
                
                # Try different temperature sensor naming conventions
                possible_temp_names = [
                    f"PSU{slot_num} TEMP",
                    f"TEMP_PSU{slot_num}",
                    f"PSU{slot_num}_TEMP",
                    f"Temperature_PSU{slot_num}"
                ]
                self.config['temp_sensor_map'][psu['name']] = possible_temp_names
    
    def test_psu_presence(self, address):
        """Test if a PSU is present at the given address"""
        try:
            if self.debug:
                print(f"Testing PSU presence at {address}...")
            # Try to read the status byte (register 0x78) - quick check
            status = run_ipmitool_command(2, address, 1, "0x78")
            if self.debug:
                print(f"  Status byte at {address}: {status}")
            # If we get a valid response (not None), PSU is present
            return status is not None
        except Exception as e:
            if self.debug:
                print(f"  Exception testing {address}: {e}")
            return False
    
    def collect(self):
        """Called by Prometheus client when metrics are scraped"""
        collection_start = time.time()

        if self.debug:
            print(f"\n[{datetime.now()}] Starting PSU collection...")
            print(f"Found {len(self.psus)} PSUs to monitor")
            print(f"Motherboard model: {self.model}")
            
        # Create metric families with octoserver prefix
        power_in = GaugeMetricFamily(
            'octoserver_psu_input_power_watts',
            'PSU AC input power consumption in watts',
            labels=['instance', 'psu', 'slot', 'model', 'serial', 'firmware', 'status', 'config', 'mode']
        )
        
        power_out = GaugeMetricFamily(
            'octoserver_psu_output_power_watts',
            'PSU DC output power in watts',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        voltage_in = GaugeMetricFamily(
            'octoserver_psu_input_voltage_volts',
            'PSU AC input voltage in volts',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        current_in = GaugeMetricFamily(
            'octoserver_psu_input_current_amperes',
            'PSU AC input current in amperes',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        voltage_out = GaugeMetricFamily(
            'octoserver_psu_output_voltage_volts',
            'PSU DC output voltage in volts',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        current_out = GaugeMetricFamily(
            'octoserver_psu_output_current_amperes',
            'PSU DC output current in amperes',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        temperature = GaugeMetricFamily(
            'octoserver_psu_temperature_celsius',
            'PSU temperature in celsius',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        fan_speed = GaugeMetricFamily(
            'octoserver_psu_fan_speed_rpm',
            'PSU fan speed in RPM',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        efficiency = GaugeMetricFamily(
            'octoserver_psu_efficiency_percent',
            'PSU efficiency percentage',
            labels=['instance', 'psu', 'slot', 'serial']
        )
        
        status_ok = GaugeMetricFamily(
            'octoserver_psu_status_ok',
            'PSU status (1=ok, 0=fault)',
            labels=['instance', 'psu', 'slot', 'status']
        )
        
        # Info metric for static labels
        info = InfoMetricFamily(
            'octoserver_psu_info',
            'PSU information',
            labels=['instance', 'psu', 'slot']
        )
        
        # Collect from each PSU
        total_power = 0
        total_power_out = 0
        total_current_in = 0
        total_current_out = 0
        max_temp = 0
        avg_efficiency_weighted = 0
        total_weight = 0
        psu_count = 0
        
        # Track current distribution for detecting imbalance
        current_distribution = []
        
        for psu in self.psus:
            try:
                if self.debug:
                    print(f"\nCollecting from {psu['name']} at {psu['address']}...")

                psu_info = collect_psu_info(psu["address"], debug=self.debug)
                
                # Skip if we couldn't read power values
                if psu_info['input_power'] == 0:
                    if self.verbose:
                        print(f"Warning: Could not read power from {psu['name']} at {psu['address']}")
                    continue
                    
                if self.debug:
                    print(f"Successfully read {psu['name']}: PIN={psu_info['input_power']:.1f}W, POUT={psu_info['output_power']:.1f}W")
                
                # Accumulate totals
                power_value = psu_info['input_power']
                total_power += power_value
                total_power_out += psu_info['output_power']
                total_current_in += psu_info['input_current']
                total_current_out += psu_info['output_current']
                
                # Track current distribution
                current_distribution.append({
                    'psu': psu['name'],
                    'current': psu_info['output_current']
                })
                
                # Get temperature from IPMI if not available from PSU
                if psu_info['temperature'] == 0:
                    temp = get_psu_temperature(psu["name"], self.config, debug=self.debug)
                    if temp is not None:
                        psu_info['temperature'] = temp
                
                max_temp = max(max_temp, psu_info['temperature'])
                
                # Calculate efficiency
                eff = 0
                if power_value > 10 and psu_info['output_power'] > 10:
                    eff = (psu_info['output_power'] / power_value) * 100
                    if eff > 99:
                        eff = 99.0
                    elif eff < 50:
                        eff = 85.0
                elif power_value > 10:
                    eff = 85.0
                
                # Accumulate weighted efficiency
                if eff > 0 and power_value > 0:
                    avg_efficiency_weighted += eff * power_value
                    total_weight += power_value
                
                psu_count += 1
                
                # Add metrics for this PSU
                power_in.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["model"], psu_info["serial"], 
                     psu_info["firmware"], psu_info["status"], psu_info["config"], psu_info.get("mode", "unknown")],
                    power_value
                )
                
                power_out.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["output_power"]
                )
                
                voltage_in.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["input_voltage"]
                )
                
                current_in.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["input_current"]
                )
                
                voltage_out.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["output_voltage"]
                )
                
                current_out.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["output_current"]
                )
                
                temperature.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["temperature"]
                )
                
                fan_speed.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                    psu_info["fan_speed"]
                )
                
                if eff > 0:
                    efficiency.add_metric(
                        [self.hostname, psu["name"], psu["slot"], psu_info["serial"]],
                        eff
                    )
                
                status_value = 1 if psu_info['status'] == 'ok' else 0
                status_ok.add_metric(
                    [self.hostname, psu["name"], psu["slot"], psu_info["status"]],
                    status_value
                )
                
                # Add info metric
                bmc_psu = self.config['bmc_mapping'].get(psu["name"], "none")
                info.add_metric(
                    [self.hostname, psu["name"], psu["slot"]],
                    {
                        'model': psu_info["model"],
                        'serial': psu_info["serial"],
                        'firmware': psu_info["firmware"],
                        'mfr_id': psu_info["mfr_id"],
                        'mfr_date': psu_info["mfr_date"],
                        'bmc_psu': bmc_psu,
                        'motherboard': self.model,
                        'exporter_version': VERSION
                    }
                )
                
                if self.verbose:
                    print(f"\n{psu['name']} ({psu['address']}) - BMC: {bmc_psu}:")
                    print(f"  PIN: {power_value:.1f}W, POUT: {psu_info['output_power']:.1f}W, "
                          f"Efficiency: {eff:.1f}%")
                    print(f"  Vout: {psu_info['output_voltage']:.2f}V, Iout: {psu_info['output_current']:.1f}A")
                    print(f"  Temp: {psu_info['temperature']:.1f}°C, Fan: {psu_info['fan_speed']:.0f} RPM")
            
            except Exception as e:
                print(f"ERROR collecting from {psu['name']}: {e}")
                if self.debug:
                    import traceback
                    traceback.print_exc()
                continue
        
        # Check for current sharing imbalance (mainly for ROMED8-2T)
        if len(current_distribution) >= 3 and self.verbose:
            currents = [p['current'] for p in current_distribution]
            min_current = min(currents)
            max_current = max(currents)
            if min_current < 5 and max_current > 30:
                print(f"\nWARNING: Possible current sharing issue detected!")
                print(f"Current distribution:")
                for p in current_distribution:
                    print(f"  {p['psu']}: {p['current']:.1f}A")
                if self.model == 'ROMED8-2T':
                    print("  Note: This is a known issue with ROMED8-2T when BMC only manages 2 of 3 PSUs")
        
        # Add aggregate metrics if we got readings
        if psu_count > 0:
            # Power totals
            power_in.add_metric(
                [self.hostname, "PowerPSUTotal", "all", "aggregate", "aggregate", 
                 "aggregate", "aggregate", "aggregate", "aggregate"],
                total_power
            )
            
            power_out.add_metric(
                [self.hostname, "PowerPSUTotal", "all", "aggregate"],
                total_power_out
            )
            
            current_in.add_metric(
                [self.hostname, "PowerPSUTotal", "all", "aggregate"],
                total_current_in
            )
            
            current_out.add_metric(
                [self.hostname, "PowerPSUTotal", "all", "aggregate"],
                total_current_out
            )
            
            # Average efficiency
            if total_weight > 0:
                avg_eff = avg_efficiency_weighted / total_weight
                efficiency.add_metric(
                    [self.hostname, "PowerPSUAverage", "all", "aggregate"],
                    avg_eff
                )
            
            # Max temperature
            temperature.add_metric(
                [self.hostname, "PowerPSUMax", "all", "aggregate"],
                max_temp
            )
            
            if self.verbose:
                print(f"\nTotals ({psu_count} PSUs):")
                print(f"  Total PIN: {total_power:.1f}W, Total POUT: {total_power_out:.1f}W")
                print(f"  Total IIN: {total_current_in:.2f}A, Total IOUT: {total_current_out:.1f}A")
                if total_weight > 0:
                    print(f"  Average Efficiency: {avg_efficiency_weighted / total_weight:.1f}%")
                print(f"  Max Temperature: {max_temp:.1f}°C")
        
        collection_duration = time.time() - collection_start
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Scrape: {psu_count} PSUs, {total_power:.0f}W, {collection_duration:.2f}s")

        # Yield all metrics
        yield power_in
        yield power_out
        yield voltage_in
        yield current_in
        yield voltage_out
        yield current_out
        yield temperature
        yield fan_speed
        yield efficiency
        yield status_ok
        yield info


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP request handler for /metrics endpoint"""

    def do_GET(self):
        if self.path == '/metrics':
            # Generate metrics
            try:
                output = generate_latest(REGISTRY)
                self.send_response(200)
                self.send_header('Content-Type', CONTENT_TYPE_LATEST)
                self.end_headers()
                self.wfile.write(output)
            except BrokenPipeError:
                # Client disconnected before we could send response - this is normal
                pass
            except ConnectionResetError:
                # Client reset connection - this is normal
                pass
            except Exception as e:
                try:
                    self.send_error(500, f"Error generating metrics: {str(e)}")
                except (BrokenPipeError, ConnectionResetError):
                    # Client already disconnected, ignore
                    pass
        elif self.path == '/':
            # Simple homepage
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                html = f"""<html>
<head><title>Octoserver PSU Power Metrics Exporter</title></head>
<body>
<h1>Octoserver PSU Power Metrics Exporter</h1>
<p>Version: {VERSION}</p>
<p>Author: {AUTHOR} &lt;{CONTACT}&gt;</p>
<p>Organization: NexGenCloud</p>
<hr>
<p><a href="/metrics">View Metrics</a></p>
<p>Default port: 9175</p>
<p>Auto-detection enabled. Check console output with --verbose flag for details.</p>
</body>
</html>"""
                self.wfile.write(html.encode())
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            try:
                self.send_error(404)
            except (BrokenPipeError, ConnectionResetError):
                pass
    
    def log_message(self, format, *args):
        # Override to reduce logging noise
        # Only log non-metrics requests
        if args and len(args) > 0 and isinstance(args[0], str) and '/metrics' not in args[0]:
            sys.stderr.write("%s - - [%s] %s\n" %
                         (self.client_address[0],
                          self.log_date_time_string(),
                          format%args))


# Include all the helper functions from the original scripts
def linear11(value):
    """Convert linear11 format to float value"""
    mantissa = value & 0x7ff
    if mantissa > 1023:
        mantissa = mantissa - 2048
    
    exponent = (value >> 11) & 0x1f
    if exponent > 15:
        exponent = exponent - 32
    
    result = mantissa * (2.0 ** exponent)
    return result


def run_ipmitool_command(bus, address, length, register):
    """Run ipmitool i2c command and return the result"""
    cmd = f"ipmitool i2c bus={bus} {address} {length} {register}"
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                check=True, timeout=SUBPROCESS_TIMEOUT)

        lines = result.stdout.strip().split('\n')
        if lines and lines[0]:
            all_bytes = []
            for line in lines:
                if line.strip():
                    bytes_data = line.strip().split()
                    all_bytes.extend(bytes_data)

            if length == 1 and len(all_bytes) >= 1:
                return int(f"0x{all_bytes[0]}", 16)
            elif length == 2 and len(all_bytes) >= 2:
                hex_value = f"0x{all_bytes[1]}{all_bytes[0]}"
                return int(hex_value, 16)
            else:
                return all_bytes
    except subprocess.TimeoutExpired:
        return None
    except subprocess.CalledProcessError:
        return None
    except Exception:
        return None


def decode_string_register(psu_address, register, length):
    """Read and decode string registers like model, serial, firmware"""
    bytes_data = run_ipmitool_command(2, psu_address, length, register)
    if bytes_data and isinstance(bytes_data, list):
        try:
            ascii_chars = []
            start_idx = 1 if len(bytes_data[0]) == 2 else 0
            
            for i in range(start_idx, len(bytes_data)):
                try:
                    byte_val = int(bytes_data[i], 16)
                    if 32 <= byte_val < 127:
                        ascii_chars.append(chr(byte_val))
                except:
                    pass
            return ''.join(ascii_chars).strip()
        except:
            pass
    return "unknown"


def read_pmbus_string(psu_address, register, debug=False):
    """Read PMBus string with proper length handling"""
    bytes_data = run_ipmitool_command(2, psu_address, 32, register)
    if not bytes_data or not isinstance(bytes_data, list):
        return "unknown"
    
    if debug:
        print(f"Debug: read_pmbus_string({psu_address}, {register}): {' '.join(bytes_data[:24])}")
    
    try:
        if len(bytes_data) > 0:
            str_length = int(bytes_data[0], 16)
            ascii_chars = []
            # Honour the PMBus block-read length byte. It was previously read
            # and then ignored, so bytes PAST the end of the string leaked in
            # whenever the trailing byte happened to be printable - producing
            # serials like "...396x" / "...300-" / "...001q". That is not
            # cosmetic: it made one PSU's serial appear on two different hosts
            # at once and sent a live PSU investigation down the wrong path.
            end = min(len(bytes_data), str_length + 1)
            for i in range(1, end):
                try:
                    byte_val = int(bytes_data[i], 16)
                    if 48 <= byte_val <= 57 or 65 <= byte_val <= 90 or 97 <= byte_val <= 122:
                        ascii_chars.append(chr(byte_val))
                    elif byte_val == 45:
                        ascii_chars.append(chr(byte_val))
                    elif byte_val == 0 or byte_val == 0xFF:
                        break
                except:
                    break
            result = ''.join(ascii_chars).strip()
            if debug:
                print(f"Debug: decoded string: '{result}' (length byte was 0x{str_length:02X})")
            return result
    except Exception as e:
        if debug:
            print(f"Error decoding string from register {register}: {e}")
    return "unknown"


def get_psu_temperature(psu_name, config, debug=False):
    """Get PSU temperature from IPMI sensors"""
    try:
        temp_sensor_map = config.get('temp_sensor_map', {})
        sensor_names = temp_sensor_map.get(psu_name)
        
        if not sensor_names:
            return None
        
        # If it's a list of possible names, try each one
        if isinstance(sensor_names, list):
            for sensor_name in sensor_names:
                temp = try_read_temperature_sensor(sensor_name, debug)
                if temp is not None:
                    return temp
        else:
            # Single sensor name
            return try_read_temperature_sensor(sensor_names, debug)
            
    except Exception as e:
        if debug:
            print(f"Error reading temperature for {psu_name}: {e}")
    return None


def try_read_temperature_sensor(sensor_name, debug=False):
    """Try to read a temperature sensor by name"""
    if not sensor_name:
        return None

    try:
        cmd = f"ipmitool sensor get '{sensor_name}' 2>/dev/null | grep 'Sensor Reading' | awk '{{print $4}}'"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                timeout=SUBPROCESS_TIMEOUT)

        if result.stdout.strip():
            try:
                temp = float(result.stdout.strip())
                if debug:
                    print(f"Debug: Temperature from sensor '{sensor_name}': {temp}°C")
                return temp
            except:
                pass
    except subprocess.TimeoutExpired:
        if debug:
            print(f"Debug: Timeout reading temperature sensor '{sensor_name}'")
    except:
        pass
    return None


# Identity registers (manufacturer, model, serial, firmware, build date) are
# constant for the life of a PSU, but were being re-read on EVERY scrape - six
# i2c round-trips per PSU per scrape, one of which read 0x9A twice for two
# fields that hold the same value. Cache them per address instead.
#
# NOTE: the CONFIG register (0x1A) is deliberately NOT cached. It carries the
# standby/active mode flag, which genuinely changes, and telling standby from
# active is central to diagnosing PSU load-sharing.
_IDENT_CACHE = {}


def collect_psu_info(psu_address, debug=False):
    """Collect all PSU information"""
    info = {
        'model': 'unknown',
        'serial': 'unknown',
        'firmware': 'unknown',
        'mfr_id': 'unknown',
        'mfr_model': 'unknown',
        'mfr_date': 'unknown',
        'status': 'unknown',
        'config': 'unknown',
        'input_voltage': 0,
        'input_current': 0,
        'input_power': 0,
        'output_voltage': 0,
        'output_current': 0,
        'output_power': 0,
        'temperature': 0,
        'fan_speed': 0,
        'status_byte': 0
    }
    
    # Static identity - read once per address, then served from cache.
    ident = _IDENT_CACHE.get(psu_address)
    if ident is None:
        model = read_pmbus_string(psu_address, "0x9A", debug)          # 0x9A
        ident = {
            'model': model,
            'mfr_model': model,          # same register - was read twice
            'serial': read_pmbus_string(psu_address, "0x9E", debug),   # 0x9E
            'firmware': decode_string_register(psu_address, "0x9B", 12),
            'mfr_id': decode_string_register(psu_address, "0x99", 8),
            'mfr_date': decode_string_register(psu_address, "0x9D", 8),
        }
        # Only cache a good read; a transient i2c failure must not pin
        # "unknown" for the life of the process. PMBus reads return zeros for
        # ~30s after a BMC cold reset, which is exactly such a transient.
        if ident['model'] not in ('unknown', '') and ident['serial'] not in ('unknown', ''):
            _IDENT_CACHE[psu_address] = ident
        elif debug:
            print(f"Debug: identity read incomplete for {psu_address}, not caching")
    info.update(ident)
    
    # CONFIG register (0x1A, 2 bytes)
    config_raw = run_ipmitool_command(2, psu_address, 2, "0x1A")
    if config_raw is not None:
        info['config'] = f"0x{config_raw:04X}"
        if config_raw in [0xF001, 0x00E1, 0x00E7, 0x00EB]:
            info['mode'] = 'standby'
        elif config_raw in [0x0238, 0x9CE, 0x9EF3, 0x20C3, 0x0002]:
            info['mode'] = 'active'
        else:
            info['mode'] = 'unknown'
    
    # Status byte (register 0x78)
    status_byte = run_ipmitool_command(2, psu_address, 1, "0x78")
    if status_byte is not None:
        info['status_byte'] = status_byte
        if status_byte == 0x00:
            info['status'] = 'ok'
        elif status_byte == 0x02:
            info['status'] = 'ok'  # CML fault is normal for these PSUs
        elif status_byte & 0x40:
            info['status'] = 'power_off'
        else:
            info['status'] = f'fault_0x{status_byte:02X}'
    
    # Read all power-related values
    
    # Input power (register 0x97, linear11 format)
    pin_raw = run_ipmitool_command(2, psu_address, 2, "0x97")
    if pin_raw is not None:
        info['input_power'] = linear11(pin_raw)
        if debug:
            print(f"Debug: {psu_address} PIN raw: 0x{pin_raw:04x} = {info['input_power']:.1f}W")
    
    # Output power (register 0x96, linear11 format)
    pout_raw = run_ipmitool_command(2, psu_address, 2, "0x96")
    if pout_raw is not None:
        info['output_power'] = linear11(pout_raw)
        if debug:
            print(f"Debug: {psu_address} POUT raw: 0x{pout_raw:04x} = {info['output_power']:.1f}W")
    
    # Input voltage (register 0x88, linear11 format)
    vin_raw = run_ipmitool_command(2, psu_address, 2, "0x88")
    if vin_raw is not None:
        info['input_voltage'] = linear11(vin_raw)
    
    # Input current (register 0x89, linear11 format)
    iin_raw = run_ipmitool_command(2, psu_address, 2, "0x89")
    if iin_raw is not None:
        info['input_current'] = linear11(iin_raw)
    
    # Output voltage (register 0x8B)
    vout_mode = run_ipmitool_command(2, psu_address, 1, "0x20")
    vout_raw = run_ipmitool_command(2, psu_address, 2, "0x8B")
    if vout_raw is not None and vout_mode is not None:
        if vout_mode == 0x17:
            info['output_voltage'] = vout_raw / 512.0
        elif vout_mode & 0x1F == 0x14:
            info['output_voltage'] = vout_raw / 4096.0
        elif vout_mode & 0x1F == 0x13:
            info['output_voltage'] = vout_raw / 8192.0
        else:
            info['output_voltage'] = vout_raw / 512.0
    
    # Output current (register 0x8C, linear11 format)
    iout_raw = run_ipmitool_command(2, psu_address, 2, "0x8C")
    if iout_raw is not None:
        info['output_current'] = linear11(iout_raw)
    
    # Temperature 1 (register 0x8D, linear11 format)
    temp_raw = run_ipmitool_command(2, psu_address, 2, "0x8D")
    if temp_raw is not None:
        info['temperature'] = linear11(temp_raw)
    
    # Fan speed (register 0x90, linear11 format)
    fan_raw = run_ipmitool_command(2, psu_address, 2, "0x90")
    if fan_raw is not None:
        info['fan_speed'] = linear11(fan_raw)
    
    # Sanity check
    if debug and info['input_power'] > 0 and info['output_power'] > 0:
        calc_efficiency = (info['output_power'] / info['input_power']) * 100
        print(f"Debug: Raw efficiency for {psu_address}: {calc_efficiency:.1f}%")
        
        if calc_efficiency > 100:
            print(f"WARNING: Impossible efficiency {calc_efficiency:.1f}% for {psu_address}")
        
        calc_pin = info['input_voltage'] * info['input_current']
        calc_pout = info['output_voltage'] * info['output_current']
        print(f"  V*I check: PIN={calc_pin:.1f}W, POUT={calc_pout:.1f}W")
    
    return info


def main():
    parser = argparse.ArgumentParser(
        description='Octoserver PSU Power Metrics Exporter',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Motherboard models:
  AUTO         - Auto-detect based on PSU count (default)
  ROMED8-2T    - ASRockRack ROMED8-2T (3 PSUs)
  ROME2D32GM-2T - ASRockRack ROME2D32GM-2T (4 PSUs)
  
Examples:
  %(prog)s --verbose                    # Auto-detect with verbose output
  %(prog)s --model ROMED8-2T            # Force ROMED8-2T configuration
  %(prog)s --max-psus 8 --debug         # Check up to 8 PSU slots with debug
  %(prog)s --port 9175                  # Run on standard port 9175

Version: {VERSION}
Author: {AUTHOR} <{CONTACT}>
Organization: NexGenCloud
        """)
    
    parser.add_argument('--port', type=int, default=DEFAULT_PORT, 
                        help=f'Port to listen on (default: {DEFAULT_PORT})')
    parser.add_argument('--host', default=DEFAULT_HOST, 
                        help=f'Host to bind to (default: {DEFAULT_HOST})')
    parser.add_argument('--max-psus', type=int, default=MAX_PSU_ADDRESSES,
                        help=f'Maximum number of PSU addresses to check (default: {MAX_PSU_ADDRESSES})')
    parser.add_argument('--model', default='AUTO',
                        choices=['AUTO', 'ROMED8-2T', 'ROME2D32GM-2T'],
                        help='Motherboard model (default: AUTO)')
    parser.add_argument('--verbose', action='store_true', 
                        help='Show detailed PSU information')
    parser.add_argument('--debug', action='store_true', 
                        help='Show debug information including raw data')
    parser.add_argument('--version', action='version',
                        version=f'%(prog)s {VERSION}')
    
    args = parser.parse_args()
    
    # Register collector
    REGISTRY.register(PSUCollector(
        debug=args.debug, 
        verbose=args.verbose,
        max_psus=args.max_psus,
        model=args.model
    ))
    
    # Start HTTP server
    server_address = (args.host, args.port)
    httpd = HTTPServer(server_address, MetricsHandler)

    # Get display IP (resolve 0.0.0.0 to actual local IP)
    if args.host == '0.0.0.0':
        try:
            # Get local IP by connecting to a public DNS (doesn't actually send data)
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            local_ip = s.getsockname()[0]
            s.close()
        except Exception:
            local_ip = socket.gethostbyname(socket.gethostname())
    else:
        local_ip = args.host

    print(f"Octoserver PSU Power Metrics Exporter v{VERSION}")
    print(f"Author: {AUTHOR} <{CONTACT}>")
    print(f"Organization: NexGenCloud")
    print("-" * 50)
    print(f"Started on {local_ip}:{args.port}")
    print(f"Metrics available at http://{local_ip}:{args.port}/metrics")
    print(f"Mode: {args.model} (auto-detection {'enabled' if args.model == 'AUTO' else 'disabled'})")
    if args.verbose:
        print(f"Maximum PSU slots to check: {args.max_psus}")
        print("Detecting PSUs...")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Octoserver PSU Exporter...")
        httpd.shutdown()
        sys.exit(0)


if __name__ == "__main__":
    main()
