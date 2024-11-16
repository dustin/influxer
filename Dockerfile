# Stage 1: Build the Haskell project
FROM haskell:9.6-bullseye AS builder

RUN apt-get update && apt-get install -y zlib1g zlib1g-dev

WORKDIR /usr/src/app

COPY cabal.project influxer.cabal ./
RUN cabal update && cabal build --only-dependencies

COPY . ./
RUN cabal install

# Stage 2: Create the final image
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y zlib1g

WORKDIR /usr/local/bin

# Copy the built executable from the builder stage
COPY --from=builder /root/.local/bin/influxer .

VOLUME /etc/influxer
WORKDIR /etc/influxer

COPY influx.conf.sample influx.conf

ENTRYPOINT ["/usr/local/bin/influxer"]
