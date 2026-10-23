# Elasticsearch with the four analysis plugins Liferay DXP expects.
# 8.19.20 is the version DXP 2026.Q3.8 and 2026.Q1.13 ship as their development sidecar.
ARG ES_VERSION=8.19.20
FROM docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}

RUN bin/elasticsearch-plugin install --batch analysis-icu && \
    bin/elasticsearch-plugin install --batch analysis-kuromoji && \
    bin/elasticsearch-plugin install --batch analysis-smartcn && \
    bin/elasticsearch-plugin install --batch analysis-stempel
