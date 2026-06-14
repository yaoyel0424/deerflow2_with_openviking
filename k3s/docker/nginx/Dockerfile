# 基于 deploy 预拉取的 node:22-alpine，用 Alpine 国内源安装 nginx（无需拉 docker.io/library/nginx）
FROM node:22-alpine

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories 2>/dev/null || true \
    && apk add --no-cache nginx

EXPOSE 2026

# nginx.conf 由 K8s ConfigMap 挂载
CMD ["nginx", "-g", "daemon off;"]
