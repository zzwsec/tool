### 新建 builder
```shell
docker buildx create \
  --name multiarch \
  --driver docker-container \
  --use \
  --bootstrap
```

### 构建
```shell
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t zzwsec/xray:latest \
  -t zzwsec/xray:v26.7.28 \
  --push .
```
