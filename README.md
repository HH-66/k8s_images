# Kubespray offline ACR builder

该仓库只负责构建 `base-cluster` 离线制品并推送到阿里云 ACR。GitHub Actions 是唯一联网构建
owner；operator host 和 h139 都不运行下载流程，CI 也不会 SSH 或部署 h139。

首版固定为 Ubuntu 24.04 / amd64、Kubespray Offline 2.31.0、Kubespray 2.31.0、
Kubernetes 1.35.4、containerd 2.2.3、etcd 3.6.10 和 Cilium 1.19.3。NFD、GPU
Operator、Kueue、KubeRay、监控、CSI 与业务镜像不属于该 bundle。

## GitHub 与 ACR 配置

bundle 固定发布到：

```text
registry.cn-shenzhen.aliyuncs.com/liuhh/k8s-images
```

GitHub 仓库只需要设置：

- Repository secrets `ACR_USERNAME`、`ACR_PASSWORD`：只允许 push 该 ACR repository 的专用
  构建账号。
- 建议用 GitHub tag protection/ruleset 保护 `bundle-v2.31.0-r*`，只允许发布管理员创建。

workflow 可由 `bundle-v2.31.0-r1` 形式的 Git tag 或 `workflow_dispatch` 触发。它不会推送
`latest`，结束时会在 job summary 输出唯一可交付引用：

```text
registry.cn-shenzhen.aliyuncs.com/liuhh/k8s-images@sha256:<digest>
```

ACR repository 应启用 tag immutability、漏洞扫描和保留策略；h139 的 pull 账号应与 CI push
账号分离，且只授予 pull 权限。若 ACR 配置了公网访问白名单，还需允许 GitHub 托管 runner 的动态出口；
无法接受动态出口时应改用具备固定出口的专用 runner。

## 本地验证

以下检查不下载任何集群制品：

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/build-bundle.sh payload/*.sh
python3 -m py_compile scripts/*.py tests/*.py
```

`scripts/build-bundle.sh` 是联网 CI 路径，会克隆固定 commit、解析 Kubespray 生成列表、用白名单
缩减为 base-cluster、下载并校验 bundle。构建脚本会先建立 upstream Python venv，再调用需要
`ansible-playbook` 的列表生成器；输出的无 `.git` Kubespray archive 带固定 tag/commit source marker，供
消费端 preflight 校验。不要在本机或 h139 上运行。

## 供应链边界

最终镜像以 `scratch` 为基底，只包含 bundle、checksum、provenance 和源镜像 manifest digest
lock。`source-images.lock` 锁定 CI 实际解析到的源镜像 manifests；bundle 内每个文件另由
`outputs/SHA256SUMS` 校验。首版尚未加入 cosign 签名，生产使用前再增加签名和 ACR 准入策略。
workflow 当前将压缩 bundle 上限设为 100 GiB；首次构建还必须核对实际大小、GitHub Actions 时长和
ACR 单层/镜像限制。超限时应拆分 artifact，而不是提高上限后继续推送。

该项目本身使用 Apache-2.0。bundle 会再分发 Kubernetes、containerd、Cilium、Ubuntu 包和
Python wheels；对组织外分发前需单独审查各上游许可证和再分发条款。
