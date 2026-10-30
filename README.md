# auto-wheels

基于 GitHub Actions 的 **wheel 构建工厂**：手动触发一次 Action、贴上一份 `requirements.txt`，
即可为**指定架构的设备**（树莓派、Jetson、ARM 服务器、Alpine 容器……）编译出 wheel，
并自动发布成一个可以用 `pip --find-links` 直接吃的静态仓库。

```
workflow_dispatch(requirements + 平台 + Python 版本)
        │
        ├─ prepare      校验输入 → 生成构建矩阵
        │
        ├─ build × N    QEMU + manylinux/musllinux 容器
        │                └ pip wheel → auditwheel repair → *.whl
        │
        └─ publish      汇总 wheel → 生成索引 → 推送 gh-pages / 归档 Release
                                     │
                                     └─ https://<owner>.github.io/<repo>/wheels/
```

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-wheels.yml` | 主流程：prepare → build（矩阵）→ publish |
| `platforms.json` | **平台目录**：镜像、docker 架构、解释器路径、是否 auditwheel 修复 |
| `scripts/make-matrix.py` | 校验输入、生成 `strategy.matrix` |
| `scripts/prepare-inputs.sh` | 把 Action 输入固化为 `ci/requirements.txt`（顺带去掉 CRLF） |
| `scripts/run-build.sh` | 宿主机侧：按 Python 版本逐个启动目标架构容器 |
| `scripts/build-wheels.sh` | 容器内：装系统依赖 → `pip wheel` → `auditwheel repair` |
| `scripts/gen_index.py` | 生成 find-links 列表页 + PEP 503 简单索引 + 首页 |
| `scripts/publish-pages.sh` | 增量发布到 `gh-pages` |
| `scripts/publish-release.sh` | 可选：额外归档到 GitHub Release |
| `requirements.txt` | 默认依赖清单（不填 `requirements_text` 时使用） |

## 一、首次准备

1. **推送仓库并开启 Pages**

   Settings → Pages → Source 选 **Deploy from a branch** → 分支 `gh-pages` → 目录 `/ (root)`。
   > 第一次运行发布时 `gh-pages` 分支会被自动创建；Pages 开启动作脚本也会尝试自动完成，
   > 但通常需要仓库管理权限，失败时按上面的路径手点一次即可。
   > 私有仓库的 Pages 需要付费套餐，否则请用 `publish_target=release`。

2. **确认 workflow 权限**

   仓库 Settings → Actions → General → Workflow permissions 选 **Read and write permissions**
   （workflow 里已声明 `permissions: contents: write`，此项用于兜底）。

## 二、触发构建

### 方式 A：网页

Actions → **Build Wheels** → *Run workflow*，填写：

| 输入 | 说明 | 示例 |
| --- | --- | --- |
| `requirements_text` | 直接粘贴 requirements 内容（多行）。留空则用仓库文件 | `numpy==1.26.4` |
| `requirements_file` | 仓库内的 requirements 路径 | `requirements.txt` |
| `platforms` | 目标平台，逗号分隔，取值见 `platforms.json` | `manylinux2014_aarch64` |
| `python_versions` | 目标 Python 版本 | `3.9,3.10,3.11,3.12` |
| `system_packages` | 额外系统依赖（编译某些包需要） | `libxml2-dev libxslt1-dev` |
| `pip_args` | 追加给 `pip wheel` 的参数 | `--prefer-binary` |
| `publish_target` | `pages` / `release` / `both` / `none` | `pages` |
| `release_tag` | Release 标签 | `wheels` |
| `pages_branch` | Pages 分支 | `gh-pages` |
| `ignore_build_errors` | 单个依赖失败是否继续 | `true` |
| `strict_repair` | auditwheel 修复失败是否报错 | `false` |

### 方式 B：命令行（适合把 requirements 文件直接“上传”）

```bash
# 用 requirements.txt 文件内容触发
gh workflow run build-wheels.yml \
  -f requirements_text="$(cat requirements.txt)" \
  -f platforms="manylinux2014_aarch64,manylinux_2_28_aarch64" \
  -f python_versions="3.11,3.12" \
  -f publish_target=pages

# 或者只指定仓库里的文件
gh workflow run build-wheels.yml -f requirements_file=deploy/requirements-prod.txt

gh run watch
```

## 三、支持的平台

| key | 设备 / 场景 | 说明 |
| --- | --- | --- |
| `manylinux2014_aarch64` | 树莓派 4/5（64 位系统）、Jetson、鲲鹏、Graviton | glibc ≥ 2.17，兼容性最广，**默认推荐** |
| `manylinux_2_28_aarch64` | Debian 12 / Ubuntu 24.04 等新系统 | glibc ≥ 2.28，工具链更新 |
| `manylinux2014_x86_64` | PC / 服务器 | 原生构建，用于验证或离线镜像 |
| `manylinux_2_28_x86_64` | 较新的 x86_64 发行版 | 同上 |
| `musllinux_1_2_aarch64` | Alpine（64 位 ARM 容器） | musl ≥ 1.2 |
| `musllinux_1_2_x86_64` | Alpine（x86 容器 / distroless） | musl ≥ 1.2 |
| `armv7l` | 树莓派 32 位 Raspberry Pi OS | Debian bookworm 基线，wheel 标签为 `linux_armv7l` |
| `musllinux_1_2_armv7l` | Alpine on 树莓派 32 位 | musl ≥ 1.2 |

新增平台只需在 `platforms.json` 里加一条（镜像、`docker_platform`、`qemu`、`interpreter`、
`repair`）。`ppc64le` / `s390x` 用同样的方式加 `quay.io/pypa/manylinux2014_ppc64le` 即可。

字段里的占位符：

* `{cptag}` → `cp311`（ABI 标签；镜像内目录形如 `/opt/python/cp311-cp311`，因此模板写作 `/opt/python/{cptag}-{cptag}/bin/python`）
* `{py}` → `3.11`（用于镜像 tag，例如 `arm32v7/python:{py}-bookworm`）

跨架构构建靠 **QEMU 用户态模拟**：`linux/arm64` 用 `arm64`，`linux/arm/v7` 用 `arm`。
因此 ARM 任务比原生慢（尤其要现场编译 C 扩展时），但 PyPI 上已有对应架构 wheel 的包
只是被下载并收进仓库，速度很快。

## 四、客户端使用（find-links）

发布完成后索引地址固定为：

```
https://<owner>.github.io/<repo>/wheels/
```

### 1. 一次性安装

```bash
# 优先使用本仓库的 wheel，缺失的仍可回落到 PyPI
pip install --find-links https://<owner>.github.io/<repo>/wheels/ \
            --prefer-binary -r requirements.txt

# 完全离线：只用本仓库
pip install --no-index \
            --find-links https://<owner>.github.io/<repo>/wheels/ \
            -r requirements.txt
```

### 2. 长期生效（设备上写一次）

Linux / macOS `~/.pip/pip.conf`，Windows `%APPDATA%\pip\pip.ini`：

```ini
[global]
find-links = https://<owner>.github.io/<repo>/wheels/
prefer-binary = true
```

环境变量等价写法：

```bash
export PIP_FIND_LINKS=https://<owner>.github.io/<repo>/wheels/
export PIP_PREFER_BINARY=1
```

### 3. 当作完整索引（可选）

`publish` 同时生成了 PEP 503 简单索引，适合完全自建源：

```bash
pip install --index-url https://<owner>.github.io/<repo>/simple/ \
            --trusted-host <owner>.github.io
```

### 4. 内网 / 离线介质

```bash
# 在联网机器上按目标平台一次性拉全量 wheel
pip download -r requirements.txt -d wheels \
    --only-binary=:all: --platform manylinux2014_aarch64 \
    --python-version 3.11 --implementation cp --abi cp311

# 或者直接下载 Pages 上的文件
wget -r -np -nH --cut-dirs=3 -A '*.whl' https://<owner>.github.io/<repo>/wheels/
```

## 五、工作细节

### 单个 Python 版本做了什么

```bash
# 容器内（简化）
<interpreter> -m pip install -U pip
<interpreter> -m pip wheel -r ci/requirements.txt -w /tmp/wheelbuild/raw  # 顺带下载已有 wheel
auditwheel repair -w wheelhouse /tmp/wheelbuild/raw/*.whl                # 打上 manylinux/musllinux 标签
```

* 纯 Python wheel（`*-none-any.whl`）和已经是 `manylinux`/`musllinux` 标签的 wheel 直接保留；
* `REPAIR=none` 的平台（如 32 位 ARM Debian）保留 `linux_armv7l` 原始标签，同平台 pip 可直接安装；
* `auditwheel` 修复失败时默认只告警并保留原始 wheel（`strict_repair=false`）。

### 构建失败的容错

`ignore_build_errors=true`（默认）时：

1. 整份清单解析失败 → 自动退化为**逐行构建**，单个包失败只记录不中断；
2. 失败清单写入 `ci/build-failures-*.txt`，并展示在 Actions 的 Job Summary 里；
3. 失败的包里已成功的其余 wheel 照常发布。

置为 `false` 则任何一个包失败都会让整个任务变红、且不发布。

### 缓存

pip 下载缓存挂在 `ci/cache/pip`，缓存 key 含平台 + Python 版本 + requirements 哈希，
重复构建同一份清单时几乎不重复下载。

### 仓库体积

`gh-pages` 是**增量**的：每次只追加新 wheel 并重新生成索引，历史 wheel 会保留。
需要瘦身时：

```bash
git checkout gh-pages
# 删除某个平台 / 某个版本的旧 wheel 后
python3 scripts/gen_index.py --site . --site-url https://<owner>.github.io/<repo>
git add -A && git commit -m "chore: 清理旧 wheel" && git push
```

### 为什么不用 Release 页面做 find-links

Release 附件页面是**分页**的（每页 10 个），wheel 一多 pip 就只能看到第一页。
因此给 pip 用的索引放在 Pages，Release 仅作为人工下载的归档通道（`publish_target=release`）。

## 六、常见问题

**Q：ARM 构建特别慢 / 超时？**
QEMU 模拟下编译 `numpy`/`scipy` 这类包可能需要几十分钟。优先确认 PyPI 是否已有该架构
wheel（有的话只是下载）；确实要现场编译时，精简 `python_versions`、减少 `platforms`，
或改用原生 ARM runner（`platforms.json` 里的 `runs_on` 换成自托管 runner 标签）。

**Q：某个包装不上 / 编译报错缺头文件？**
把对应的系统包名填到 `system_packages`，例如 `lxml` → `libxml2-dev libxslt1-dev`，
`cryptography` → `libssl-dev libffi-dev`，`psycopg2` → `libpq-dev`。
（manylinux 镜像里是 `*-devel` 命名，脚本会自动适配 yum/apt/apk。）

**Q：`pip` 在设备上还是去 PyPI 下 sdist？**
加 `--prefer-binary`，或直接用 `--no-index` 强制只从 find-links 取。

**Q：索引更新了但网页还是旧的？**
Pages 构建有几十秒延迟；`gh-pages` 分支上能看到最新提交即说明成功。

**Q：想给团队内网一张“全部依赖”的 wheelhouse？**
`pip download --only-binary=:all:` 按平台拉全量，或用本仓库的 `/simple/` 索引做私有源。

## 七、本地调试（可选）

```bash
# 只验证索引生成
python3 scripts/gen_index.py --site ./publish --site-url https://example.github.io/repo

# 直接在本机用 manylinux 容器构建（需 docker + linux 容器）
docker run --rm -v "$PWD:/io" -w /io \
  -e REQUIREMENTS_FILE=/io/requirements.txt \
  -e OUT_DIR=/io/wheelhouse -e REPAIR=auditwheel \
  quay.io/pypa/manylinux2014_x86_64 \
  bash -c '/opt/python/cp311-cp311/bin/python -m pip wheel -r /io/requirements.txt -w /io/wheelhouse'
```

> Windows 上的 Git Bash 里跑 docker 时，记得先 `export MSYS_NO_PATHCONV=1`，
> 否则 `-w /io` 会被改写成 Windows 路径。
