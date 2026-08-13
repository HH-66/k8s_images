# Kubespray offline ACR builder

该仓库负责构建彼此独立的 `base-cluster` 和 add-on 离线制品并推送到阿里云 ACR。GitHub Actions 是唯一联网构建
owner；operator host 和 h139 都不运行下载流程，CI 也不会 SSH 或部署 h139。

首版固定为 Ubuntu 24.04 / amd64、Kubespray Offline 2.31.0、Kubespray 2.31.0、
Kubernetes 1.35.4、containerd 2.2.3、etcd 3.6.10 和 Cilium 1.19.3。NFD、GPU
Operator、Kueue、KubeRay、监控、CSI 与业务镜像不属于 base bundle。首个独立 add-on artifact 是
NFD 0.19.0，只携带正式 release chart、linux/amd64 镜像、Helm 3.18.4 和校验元数据。
第二个独立 add-on artifact 是 GPU Operator 26.3.3，面向 host driver pilot，只携带正式 release chart、
operator/validator、container toolkit、device plugin/GFD 和 DCGM Exporter 的四个 linux/amd64 镜像以及
Helm 3.18.4。所有启用或禁用路径均改写为 h139 本地 registry，禁止运行时回落公网 registry。

第三个独立 add-on artifact 是 scheduler-plugins `v0.35.4-devel`。上游只发布了未签名 Git tag，且该
tag 的 chart 元数据仍为 0.34.7、官方 registry 没有同名镜像，因此 builder 从固定 tag object、commit 和
source tree 构建 linux/amd64 scheduler 镜像，并从同一 commit 打包版本修正为 0.35.4-devel 的 chart。
该 source 的 Go module 精确依赖 Kubernetes 1.35.4。上游 Makefile 会把 devel tag 错误编码为
`gitVersion=v0.35.4`，与 Kubernetes 1.35 的 compatibility-version 校验不兼容；builder 因此显式编码
`gitVersion=v1.35.4`，并运行二进制 `--version` 检查。h139 只启用 `NodeResourceTopologyMatch` 第二调度器，
不部署 controller，也不启用 Coscheduling 或 CapacityScheduling。

第四个独立 add-on artifact 是 Kueue `v0.19.0`。builder 固定未签名 tag object、source commit/tree、
官方 release chart SHA-256 和 linux/amd64 controller image manifest digest。h139 首次安装仅启用
`batch/job` integration；RayJob integration 要等 KubeRay CRD 安装后再显式启用，避免以延迟发现 API
冒充已经完成的运行时闭环。

第五个独立 add-on artifact 是 KubeRay Operator `v1.6.2` 和 Ray runtime `2.56.1`。builder 从固定
KubeRay commit/tree 打包 operator chart，携带 operator 与 CPU Ray runtime 的 linux/amd64 manifest、
Apache-2.0 licenses 和 Helm 3.18.4。Ray runtime 仅作为 RayJob 控制面与调度验收镜像；真实训练使用的
CUDA/PyTorch 业务镜像仍由训练项目单独构建和批准。

etcd 固定使用 Kubespray 的 `etcd_deployment_type: kubeadm`，因此 bundle 同时携带
`quay.io/coreos/etcd:v3.6.10` 容器镜像和 etcd 二进制 tar：前者用于 stacked-etcd static Pod，后者供
containerd 路径安装 `etcdctl`/`etcdutl`。该模式只支持干净新建集群，不能用于把已有 host-etcd 集群
原地转换为 kubeadm etcd。

bundle 同时携带固定 SHA-256 的 Cilium 1.19.3 Helm chart，并使用官方
`quay.io/cilium/operator-generic` 镜像；消费端通过本地 chart directory 安装，不访问 Helm repository。

## GitHub 与 ACR 配置

bundle 固定发布到：

```text
registry.cn-shenzhen.aliyuncs.com/liuhh/k8s-images
```

GitHub 仓库只需要设置：

- Repository secrets `ACR_USERNAME`、`ACR_PASSWORD`：只允许 push 该 ACR repository 的专用
  构建账号。
- 建议用 GitHub tag protection/ruleset 保护 `bundle-v2.31.0-r*`，只允许发布管理员创建。

workflow 可由 `bundle-v2.31.0-r1`、`addon-nfd-v0.19.0-r1`、
`addon-gpu-operator-v26.3.3-r1` 形式的 Git tag 或
`addon-scheduler-plugins-v0.35.4-devel-r1` 形式的 Git tag 或
`workflow_dispatch` 触发。手动触发时 `artifact` 必须与 `release_tag` 前缀一致。它不会推送
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
bash -n scripts/build-bundle.sh payload/*.sh addons/*/scripts/*.sh addons/*/payload/*.sh
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
