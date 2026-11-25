# -------------------------------------------
# ---- Stage 1: build the site with Hugo ----
# -------------------------------------------
FROM debian:bookworm-slim AS build


# SHELL changes which shell runs every following RUN in this stage. The default is ["/bin/sh", "-c"], 
# and on Debian /bin/sh is dash, a minimal shell that doesn't support pipefail. 
# Debian already includes bash, so nothing needs installing.

# -o pipefail makes a pipeline fail if any command in it fails, not just the last one. 
# In curl ... | tar ..., a failed download now stops the build immediately with curl's own error message 
# (for example 404), instead of a confusing tar error like "not in gzip format".
# -c means "run the following string as a command". RUN appends your command after it.
# It applies per stage. Stage 2 starts fresh with its own default shell, which is fine because it has no RUN lines.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]


# You can override it without editing the file: <docker build --build-arg HUGO_VERSION=0.170.0 -t mysite:dev .>
# an ARG declared after a FROM belongs only to that stage. Stage 2 can't see HUGO_VERSION, and doesn't need to.
# Cache effect: if the value changes, Docker reruns the first RUN that uses the variable and everything after it, 
# not the line where it's declared.
ARG HUGO_VERSION=0.169.0

# It has no =value because BuildKit supplies the value. 
# You still have to declare it inside the stage to use it there, which is a common gotcha.
ARG TARGETARCH

# -y answers "yes" automatically, because there's no one to type it during a build.
# --no-install-recommends skips optional suggested packages, which keeps the layer small.
# ca-certificates: the trusted root certificates. Without them, curl can't verify https://github.com and the download fails.
# rm -rf /var/lib/apt/lists/* deletes the downloaded package lists, which are no longer needed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

# curl: downloads files over HTTP(S)
# (1) -f treats HTTP errors (404 and so on) as failures instead of saving the error page.
# (2) -s makes curl silent, so it doesn't print progress to the console.
# (3) -S makes curl print an error message if it fails.
# (4) -L follows redirects, which GitHub uses for downloads.
# | (pipe) sends the download straight into tar without saving a temporary file. 
# The archive never lands on disk, so it doesn't take up space in the layer.

# | (pipe) sends the download straight into tar without saving a temporary file. 
# The archive never lands on disk, so it doesn't take up space in the layer.
# tar -xz -C /usr/local/bin hugo:
  # - x: extract
  # - z: decompress gzip
  # - C: change to this directory before extracting (ATTENTION: It's on the PATH, so hugo becomes a command.)
# The final hugo extracts only that one file. The archive also contains a README and a LICENSE.
RUN curl -fsSL "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin hugo

# sets the working directory for the next instructions. If it doesn't exist, Docker creates it.
WORKDIR /src

# The COPY instruction copies files from the host into the image. 
# The first argument is the source on the host, and the second is the destination in the image (/src).
# Caching works differently here than for RUN. For COPY, Docker computes a checksum of the actual file contents. 
# If any copied file changed, even by one character, this layer and everything after it rebuild.

# This is where the order pays off. Everything above this line (Debian, apt, the Hugo download) depends only on the Dockerfile text, 
# so it stays cached when you edit your site. Only this line and the build below it rerun.
COPY . .

# Runs Hugo in /src, where it finds your config and content and writes the finished site to /src/public.
# --minify removes unnecessary whitespace and comments from HTML, CSS, JS, JSON and XML, 
# so files are smaller and load faster.
# --gc ("garbage collect") removes unused cache files after the build. 
# In a throwaway build stage it doesn't matter much, but it's harmless.
RUN hugo --minify --gc


# ----------------------------------------------------
# ---- Stage 2: serve the static files with nginx ----
# ----------------------------------------------------
# A second FROM starts a new, empty stage. Nothing from stage 1 comes along automatically

# The final image is the last stage only. That's the main idea of multi-stage builds: 
# the heavy build tools stay behind, and you ship only the result. 
# Your final image will be tens of MB instead of hundreds.
# serves files from /usr/share/nginx/html on port 80, with index.html as the index file.

FROM nginx:stable-alpine

# --from=build copies from the build stage instead of from your machine. This is the bridge between the two stages.
# It copies the contents of public/ into nginx's web root. The image's default welcome page is replaced by your index.html.
COPY --from=build /src/public /usr/share/nginx/html

# This is documentation only. 
# It records in the image's metadata that the app listens on port 80, and doesn't open or publish anything.
# Publishing happens at run time with -p. Tools can read it, though: 
# docker run -P (capital P) publishes all exposed ports to random host ports.
EXPOSE 80