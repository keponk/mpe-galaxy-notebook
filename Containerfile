# MPE Jupyter container used for Galaxy Interactive Tools integration
# Supported kernels: Python (base env), R and Bash (separate envs).
# Base: quay.io/jupyter/base-notebook (mamba-managed env root at /opt/conda)
# https://jupyter-docker-stacks.readthedocs.io/en/latest/using/selecting.html
FROM quay.io/jupyter/base-notebook:python-3.12

# SHELL does not propagate from the parent image; needed for pipefail in the
# neovim download below.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.authors="Joel Gil, joel.gil@famgil.eu"

ENV DEBIAN_FRONTEND=noninteractive


USER root

# R pre-requisites and system packages
RUN apt-get update --yes \
    && apt-get install --yes --no-install-recommends \
        curl \
        fonts-dejavu \
        gcc \
        gfortran \
        git \
        libegl-mesa0 \
        nano \
        net-tools \
        procps \
        r-cran-rodbc \
        tzdata \
        unixodbc \
        unixodbc-dev \
        unzip \
        vim \
        wget \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install neovim. The SHELL directive above (bash + pipefail) does not
# propagate from the parent image, so the pipe actually fails on curl errors.
RUN curl -sL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
    | tar -xz --strip-components=1 --overwrite -C /usr

USER 1000

# Bioconda is required for galaxy-ie-helpers/bioblend.
# (conda config, not mamba: mamba has no config command)
RUN conda config --system --add channels bioconda \
    && conda config --system --add channels conda-forge \
    && conda config --system --set channel_priority strict

# Install python and jupyter packages
RUN mamba install --yes \
    bioblend \
    galaxy-ie-helpers \
    cloudpickle \
    cython \
    dill \
    jupytext \
    jupyterlab-katex \
    jupyterlab-fasta \
    patsy \
    statsmodels \
    && mamba create -n bash-kernel --yes bash_kernel=0.10.0 bioblend galaxy-ie-helpers \
    && mamba run -n bash-kernel python -m bash_kernel.install --user \
    && mamba create -n rlang-kernel --yes r-base r-xml rpy2 bioblend galaxy-ie-helpers \
        'r-crayon' \
        'r-devtools' \
        'r-htmltools' \
        'r-htmlwidgets' \
        'r-irkernel=1.3.2' \
        'r-rmarkdown' \
        'r-rsqlite' \
        'r-shiny' \
        'r-tidyverse' \
    && mamba run -n rlang-kernel R -e "IRkernel::installspec(user = TRUE, name = 'rlang-kernel', displayname = 'R')" \
    && mamba clean --all -y

# The R kernel must see the conda env prefix and its binary/share paths.
RUN echo 'Sys.setenv(CONDA_PREFIX = "/opt/conda/envs/rlang-kernel")' >>"/home/$NB_USER/.Rprofile" \
    && echo 'Sys.setenv(PATH = paste("/opt/conda/envs/rlang-kernel/bin", Sys.getenv("PATH"), sep=":"))' >>"/home/$NB_USER/.Rprofile" \
    && echo 'Sys.setenv(PROJ_LIB = "/opt/conda/envs/rlang-kernel/share/proj")' >>"/home/$NB_USER/.Rprofile" \
    && chown "$NB_USER" "/home/$NB_USER/.Rprofile"

COPY ./startup.sh /startup.sh
#COPY ./monitor_traffic.sh /monitor_traffic.sh
COPY ./get_notebook.py /get_notebook.py

# We can get away with just creating this single file and Jupyter will create the rest of the
# profile for us.
RUN mkdir -p "/home/$NB_USER/.ipython/profile_default/startup/" \
    && mkdir -p "/home/$NB_USER/.jupyter/custom/"

COPY ./ipython-profile.py /home/$NB_USER/.ipython/profile_default/startup/00-load.py
COPY jupyter_notebook_config.py /home/$NB_USER/.jupyter/
COPY jupyter_lab_config.py /home/$NB_USER/.jupyter/

COPY ./custom.js /home/$NB_USER/.jupyter/custom/custom.js
COPY ./custom.css /home/$NB_USER/.jupyter/custom/custom.css
COPY ./default_notebook.ipynb /home/$NB_USER/notebook.ipynb

# ENV variables to replace conf file
ENV DEBUG=false \
    GALAXY_WEB_PORT=10000 \
    NOTEBOOK_PASSWORD=none \
    CORS_ORIGIN=none \
    DOCKER_PORT=none \
    API_KEY=none \
    HISTORY_ID=none \
    REMOTE_HOST=none \
    GALAXY_URL=none

# @jupyterlab/google-drive  not yet supported

USER root

# /import will be the universal mount-point for Jupyter
# The Galaxy instance can copy in data that needs to be present to the Jupyter webserver
RUN mkdir -p /import/jupyter/outputs/ \
    && mkdir -p /import/jupyter/data \
    && mkdir /export/ \
    && chown -R "${NB_USER}:users" "/home/$NB_USER/" /import /export/ \
    && chmod -R 777 "/home/$NB_USER/" /import /export/

##USER jovyan

WORKDIR /import

# Start Jupyter Notebook
CMD ["/startup.sh"]
