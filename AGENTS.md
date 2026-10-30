# AGENTS.md — mpe-galaxy-notebook

This repo is a fork of the [Galaxy Project's docker-jupyter-notebook](https://github.com/bgruening/docker-jupyter-notebook)
(MIT licensed, by Björn Grüning). It builds the Jupyter container that Galaxy launches as an
"Interactive Tool": Galaxy starts the container, injects configuration via environment variables
(`API_KEY`, `GALAXY_URL`, `HISTORY_ID`, `PROXY_PREFIX`, `CORS_ORIGIN`, ...), proxies it behind the
Galaxy UI, and the notebook can then `get()`/`put()` datasets from/to the user's Galaxy history via
`bioblend` and `galaxy-ie-helpers`. Anything mounted or downloaded lands in `/import`, which is the
container's root working directory.

## Files at a glance

### `Dockerfile`
The core of the image. Starts from `quay.io/jupyter/julia-notebook:python-3.12` as base (Julia
kernel included out of the box, chosen because it's the hardest to add later), configures
bioconda/conda-forge channels, then conda-installs the Galaxy plumbing (`bioblend`,
`galaxy-ie-helpers`) plus extra kernels in separate conda envs: bash, ansible, octave, and
R (`rlang-kernel` with a large tidyverse/tidymodels stack). Copies in the repo's scripts and config
(`startup.sh`, `get_notebook.py`, `ipython-profile.py`, both jupyter config files, `custom.js/css`,
`default_notebook.ipynb`), declares the Galaxy env vars, installs system packages for R/ODBC,
creates `/import` (universal data mount-point shared with Galaxy) and `/export`, and finally runs
`/startup.sh`. **This is the file we'll touch most** when adapting it for MPE (kernels, packages,
mount points).

### `startup.sh`
Container entrypoint (referenced by the Dockerfile's `CMD`). Deals with a Galaxy permission
quirk: Galaxy mounts `/import` with the UID/GID of the Galaxy server user (typically 1450), so the
script documents and handles running Jupyter as either the preconfigured `jovyan` user or a
newly-created `galaxy` user matching `/import`. Then runs `get_notebook.py`, marks the notebook
trusted (`jupyter trust`), and launches the classic `jupyter notebook`. Note: despite the repo
being called "jupyterlab", **it currently starts the classic notebook server**, not
`jupyter lab` — a candidate change if the goal is a real JupyterLab experience.

### `get_notebook.py`
First thing `startup.sh` runs. Using `bioblend` + `galaxy_ie_helpers` it pulls the notebook dataset
from the Galaxy history: if `DATASET_HID` is set, it fetches dataset number HID into `/import` and
copies it over `/import/ipython_galaxy_notebook.ipynb` (this is the notebook the user will edit,
and the one the green "Save to Galaxy" button writes back). Also supports `ADDITIONAL_IDS` (comma
separated dataset IDs) to pre-fetch extra datasets from the history, e.g. additional notebooks.

### `jupyter_notebook_config.py`
Config for the **classic notebook server** (`NotebookApp`/`ServerApp`). Boilerplate-trimmed, ~40
active lines: builds a permissive `Content-Security-Policy` and `X-Frame-Options: ALLOWALL` header
set from `CORS_ORIGIN` so the notebook can be iframed into the Galaxy UI, sets `base_url` and
static URL prefix from `PROXY_PREFIX` so cookies/sessions line up with Galaxy's proxy, listens on
`0.0.0.0`, empty token/password by default (matches Galaxy's proxy-based auth; the Galaxy admin
token is delegated to the proxy), and honors `NOTEBOOK_PASSWORD`/`CORS_ORIGIN` from the env when
set.

### `jupyter_lab_config.py`
Near-identical twin of `jupyter_notebook_config.py` for **JupyterLab**. It's the same
~42k-lines boilerplate with the same handful of active Galaxy lines at top and bottom (CSP headers,
password, `allow_origin`). Interesting: the Dockerfile copies this file into the image, but
`startup.sh` launches `jupyter notebook`, so **this config appears unused in practice today**.
This asymmetry is relevant to our migration to JupyterLab — one of these two configs should
become the single source of truth.

### `ipython-profile.py`
Installs IPython-specific customizations. Copied by the Dockerfile to
`~/.ipython/profile_default/startup/00-load.py`, i.e. executed every time an IPython kernel
boots, not just at container start. Here it imports `get`, `put`, `get_galaxy_connection` from
`galaxy_ie_helpers`, making them directly callable inside every Python notebook cell without
imports. Also reads `HISTORY_ID` into the kernel namespace. This is how notebooks "just know"
how to talk to Galaxy, so keep behavior identical if we rename/migrate things.

### `custom.js`
Injected by the Dockerfile into `~/.jupyter/custom/`. Top half preserves boilerplate docs; the
actual content enables 5-second autosave, adds cell-move keyboard shortcuts (ctrl-k/ctrl-j), and —
most importantly — defines the **"Save the current notebook in Galaxy"** toolbar button: it saves
the notebook and executes `put("ipython_galaxy_notebook.ipynb", "ipynb")` in the kernel, pushing
the .ipynb back into the Galaxy history via galaxy-ie-helpers. Note it uses the classic-notebook
JS API (`IPython.*`, `Jupyter.toolbar`), which **won't work in JupyterLab** — it will need a
JupyterLab extension or rewritten integration for our fork.

### `custom.css`
Tiny companion stylesheet for `custom.js`, makes the "Save the current notebook in Galaxy" toolbar
button (#saveToGalaxy id) green with a subtle text shadow. Classic-notebook specific.

### `default_notebook.ipynb`
Welcome notebook copied by the Dockerfile to `~/notebook.ipynb`. Explains the get/put idiom for
Python kernels (`get(42)`, `put('filename.txt')`) and for R/Julia kernels via the CLI (`system('get -i 42')`),
and mentions the Save-to-Galaxy button. Still declares `Python 2.7` in its kernelspec — legacy
metadata worth cleaning when we touch it.

### `monitor_traffic.sh`
Idle-user watchdog: a loop that every `DEFAULT_CONTAINER_RUNTIME` seconds (default 240s) checks
`netstat` for live TCP connections to server port 8888 and `pkill jupyter`s (thereby killing the
container) when there are fewer than 3 non-CLOSE_WAIT connections, so Galaxy reclaims idle
instances. Currently **disabled in the Dockerfile** (its ADD is commented out, as is the startup
invocation) — listed here for completeness, in case we want idle-kill behavior in our deployment.

### `README.md`
Upstream documentation: how to build/pull/run the image (`quay.io/galaxy/docker-jupyter-notebook`),
plus the table of user-facing environment variables (`API_KEY`, `CORS_ORIGIN`, `DEBUG`,
`GALAXY_URL`, `GALAXY_WEB_PORT`, `HISTORY_ID`, `NOTEBOOK_PASSWORD`, `PROXY_PREFIX`). Useful as the
contract between Galaxy and this container; will need updating as we adapt the tool.

### `LICENSE`
MIT license, copyright 2014 Björn Grüning. Forking/modifying is fine; leave the notice intact.

### CI (`.github/workflows/`)
Not files we edit per se, but two workflows exist: **`pr.yml`** builds the Docker image on PRs to
main/master (build only, no push — handy free validation of Dockerfile changes), while
**`release.yml`** builds and pushes the image to `quay.io/galaxy/docker-jupyter-notebook:tag` when
a release is published — note it pushes to the **upstream** Galaxy quay.io namespace and uses a
`QUAY_OAUTH_TOKEN` secret we likely don't have; our fork should retarget this to our own registry
(or remove it) before our first release.

### `.gitignore`
Standard Python-originated ignore list (byte-compiled files, packaging artifacts, coverage,
virtualenvs, editor junk). Nothing Galaxy-specific, no action needed.

## Notes for our adaptation (initial observations)

- The repo is named jupyterlab but actually runs **classic notebook**; migrating to
  `jupyter lab` in `startup.sh` + pruning the duplicate config files is the obvious first step.
- The Galaxy↔notebook integration has three pillars to preserve: env-var contract
  (`HISTORY_ID`, `API_KEY`, `GALAXY_URL`, `PROXY_PREFIX`, `CORS_ORIGIN`), the `/import` mount +
  UID matching in `startup.sh`, and the `get`/`put` helpers (kernel-level via
  `ipython-profile.py`, CLI-level via `galaxy-ie-helpers`).
- `custom.js`/`custom.css` Save-to-Galaxy integration is classic-notebook-only and needs a
  JupyterLab-native replacement.
- `monitor_traffic.sh` is currently dead code upstream.
