FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      pciutils ocl-icd-libopencl1 libgmp10 kmod python3 python3-rich \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/OpenCL/vendors \
    && echo libnvidia-opencl.so.1 > /etc/OpenCL/vendors/nvidia.icd

COPY bin/ /opt/cpayne/bin/
COPY compare.ptx preflight.sh restore.sh /opt/cpayne/
COPY c-payne/ /opt/cpayne/c-payne/
COPY docker/entrypoint.sh docker/aer-watch.sh /opt/cpayne/docker/

# drop bundled binaries that the host driver / distro packages must provide instead:
# nvidia-smi (nvidia-container-toolkit injects the host's matching one),
# busybox/dd/strace/lspci/setpci (distro versions installed above or built in)
RUN rm -f /opt/cpayne/bin/nvidia-smi /opt/cpayne/bin/busybox /opt/cpayne/bin/dd \
          /opt/cpayne/bin/strace /opt/cpayne/bin/lspci /opt/cpayne/bin/setpci \
    && chmod +x /opt/cpayne/docker/*.sh /opt/cpayne/*.sh /opt/cpayne/bin/*

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

WORKDIR /opt/cpayne
ENTRYPOINT ["/opt/cpayne/docker/entrypoint.sh"]
CMD ["menu"]
