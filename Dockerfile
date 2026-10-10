FROM dart:stable AS build
WORKDIR /app
COPY bin/ ./bin/
RUN dart compile exe bin/sadiah_relay_gateway.dart -o /app/sadiah-relay

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --no-create-home sadiah
COPY --from=build /app/sadiah-relay /usr/local/bin/sadiah-relay
USER 10001
ENV PORT=8080
EXPOSE 8080
CMD ["/usr/local/bin/sadiah-relay"]
