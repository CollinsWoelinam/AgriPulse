FROM python:3.12-slim

WORKDIR /app
# rasterio's wheel bundles GDAL but links the system libexpat.
RUN apt-get update && apt-get install -y --no-install-recommends libexpat1 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-dev.txt

COPY pytest.ini ./
COPY app ./app
COPY tests ./tests

# Fast remote COG reads: don't list S3 "directories", only fetch .tif sidecars.
ENV GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR \
    CPL_VSIL_CURL_ALLOWED_EXTENSIONS=.tif \
    GDAL_HTTP_MULTIRANGE=YES \
    GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES \
    AWS_NO_SIGN_REQUEST=YES

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
