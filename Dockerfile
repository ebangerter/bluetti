FROM oven/bun:latest AS bun-image

FROM python:3.13-slim-bookworm

RUN pip install --no-cache-dir bleak==2.0.0 crcmod==1.7 PyMySQL==1.1.3

COPY --from=bun-image /usr/local/bin/bun /usr/local/bin/bun

COPY bluetti_reader.py /app/bluetti_reader.py
COPY dashboard/package.json dashboard/bun.lock dashboard/server.ts dashboard/index.html /app/dashboard/
RUN cd /app/dashboard && bun install --frozen-lockfile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5000
VOLUME /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["--mysql", "--csv", "/data/data.csv", "--loop", "0", "--interval", "60"]
