# Fulcrum backtest sim with its data baked in: Binance 1m ETH/BTC prices (2020-01 -> 2026-10) and the
# 600-account Hyperliquid sample, so any machine reproduces the exact same runs without downloading anything.
#
#   docker run --rm -v "$PWD:/out" ghcr.io/niraj-kamdar/fulcrum-sim export.py /out/results.json
#   docker run --rm ghcr.io/niraj-kamdar/fulcrum-sim run.py crash --set p_10x=1
#   docker run --rm -v "$PWD/sim:/app/sim" ghcr.io/niraj-kamdar/fulcrum-sim test_model.py   # your working copy
FROM python:3.12-slim
LABEL org.opencontainers.image.source=https://github.com/Niraj-Kamdar/decentralised-prop-trading
LABEL org.opencontainers.image.description="Fulcrum backtest simulator with embedded price and trader data"
RUN pip install --no-cache-dir numpy matplotlib ipywidgets nbformat nbconvert ipykernel
# data first: code changes then only push the small code layer
COPY data /data
ENV SIM_DATA=/data PYTHONUNBUFFERED=1
WORKDIR /app/sim
COPY *.py *.ipynb ./
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA
ENTRYPOINT ["python"]
CMD ["export.py", "/out/results.json"]
