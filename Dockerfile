FROM nfcore/base@sha256:2043dea2e3215a32576e2e9fa957d8d41f439d209abbf1f858fd02829d2b7d64
#FROM nfcore/base:1.10.2

LABEL authors="Christina Chatzipantsiou" \
      description="Docker image containing all software requirements for the siteqc pipeline"


# Install the conda environment
COPY environment.yml /
RUN conda env create --quiet -f /environment.yml && conda clean -a

# Add conda installation dir to PATH (instead of doing 'conda activate')
ENV PATH /opt/conda/envs/siteqc-1.0dev/bin:$PATH

# Dump the details of the installed packages to a file for posterity
RUN conda env export --name nf-core-siteqc-1.0dev > nf-core-siteqc-1.0dev.yml

# Instruct R processes to use these empty files instead of clashing with a local version
RUN touch .Rprofile
RUN touch .Renviron


# Install GAWK
RUN apt-get update && \
    apt-get install -y \
                   gawk

