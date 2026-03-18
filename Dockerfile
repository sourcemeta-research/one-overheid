FROM ghcr.io/sourcemeta/one:4.1
COPY one.json .
COPY build/schemas schemas
RUN sourcemeta one.json --profile
