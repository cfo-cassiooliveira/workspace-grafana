# Grafana OSS 13.3.1 + plugin do OpenSearch, ambos fixados (Art. IV.7). A imagem oficial do OSS é "grafana/grafana":
# o repositório "grafana/grafana-oss" parou em 13.0.2 no Docker Hub (a tag 13.3.1 não existe nele).
# Ao atualizar: leia o "What's new"/breaking changes da versão, troque tag e digest juntos e rode scripts/smoke-test.sh.
FROM grafana/grafana:13.3.1@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf

# Plugin instalado no build (nunca por GF_INSTALL_PLUGINS em runtime). Licença Apache-2.0, assinado pela Grafana Labs.
ARG OPENSEARCH_PLUGIN_VERSION=2.34.7

# Fora de /var/lib/grafana: o volume grafana-data cobriria o plugin instalado na imagem.
ENV GF_PATHS_PLUGINS=/opt/grafana-plugins
USER root
RUN mkdir -p "${GF_PATHS_PLUGINS}" \
 && chown 472:0 "${GF_PATHS_PLUGINS}" \
 && chmod 0755 "${GF_PATHS_PLUGINS}"
USER 472
RUN grafana cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install grafana-opensearch-datasource "${OPENSEARCH_PLUGIN_VERSION}"
# Em runtime o diretório de plugins é somente leitura para o usuário do Grafana: o chown para 472 valeu só na instalação.
USER root
RUN chown -R root:root "${GF_PATHS_PLUGINS}" \
 && chmod -R go-w "${GF_PATHS_PLUGINS}"
USER 472
