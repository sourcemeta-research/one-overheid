FROM ghcr.io/sourcemeta/one:5.0
COPY one.json .
COPY build/schemas schemas
RUN sourcemeta one.json --profile
