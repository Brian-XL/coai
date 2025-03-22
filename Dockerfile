# 多阶段构建优化版Dockerfile 
# 改进点：依赖管理/缓存优化/多架构支持/安全加固 
 
# ----------------- 后端构建阶段 ----------------- 
FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS backend 
 
# 基础配置 
WORKDIR /backend 
COPY go.mod  go.sum  ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x 
 
# 设置编译环境 
ARG TARGETARCH TARGETOS 
ENV GOOS=$TARGETOS GOARCH=$TARGETARCH \
    CGO_ENABLED=1 GO111MODULE=on \
    GOPROXY=https://goproxy.cn,direct  
 
# 安装编译工具链（使用国内镜像加速）
RUN apk add --no-cache --virtual .build-deps \
    gcc musl-dev g++ make linux-headers \
    && case "$TARGETARCH" in \
        arm64) \
        wget -q -O /tmp/cross.tgz  https://mirrors.ustc.edu.cn/musl.cc/aarch64-linux-musl-cross.tgz  \
        && tar -xf /tmp/cross.tgz  -C /usr/local \
        && ln -s /usr/local/aarch64-linux-musl-cross/bin/aarch64-linux-musl-* /usr/bin/ \
        ;; \
    esac 
 
# 源码构建 
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    if [ "$TARGETARCH" = "arm64" ]; then \
        CC=aarch64-linux-musl-gcc \
        go build -trimpath -ldflags="-s -w -extldflags=-static" -o chat . ; \
    else \
        go build -trimpath -ldflags="-s -w" -o chat . ; \
    fi 
 
# ----------------- 前端构建阶段 ----------------- 
FROM node:18-alpine AS frontend 
 
WORKDIR /app 
COPY app/package.json  app/pnpm-lock.yaml  ./
 
# 依赖安装（使用国内镜像）
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    npm config set registry https://registry.npmmirror.com  \
    && npm install -g pnpm \
    && pnpm install --frozen-lockfile 
 
# 构建生产版本 
COPY app .
RUN pnpm build && \
    find dist -type f -exec gzip -k9 {} \; # 预压缩静态资源 
 
# ----------------- 运行时镜像 ----------------- 
FROM alpine:3.19 
 
# 系统级配置 
RUN echo "Asia/Shanghai" > /etc/timezone \
    && apk upgrade --no-cache \
    && apk add --no-cache ca-certificates tzdata \
    && update-ca-certificates \
    && adduser -D -u 1000 appuser 
 
# 文件复制 
COPY --from=backend --chown=appuser /backend/chat /chat 
COPY --from=backend --chown=appuser /backend/config.example.yaml  /defaults/
COPY --from=frontend --chown=appuser /app/dist /app/dist 
 
# 运行时配置 
USER appuser 
VOLUME ["/config", "/logs", "/storage"]
EXPOSE 8094 
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --spider http://localhost:8094/api/health || exit 1 
 
ENTRYPOINT ["/chat", "--config", "/config/config.yaml"] 
CMD ["--log-level", "info"]
