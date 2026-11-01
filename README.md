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
| `scripts/build-psycopg-binary.sh` | ARMv7：自动解析并源码构建 `psycopg-binary`，再打包 libpq |
| `scripts/psycopg_binary_helper.py` | 解析版本、源码改名、wheel 动态库打包与校验 |
| `scripts/gen_index.py` | 生成 find-links 列表页 + PEP 503 简单索引 + 首页 |
| `scripts/publish-pages.sh` | 增量发布到 `gh-pages`（分支不存在时自动创建） |
| `scripts/init-pages-branch.sh` | 可选：手动先建一个空的 `gh-pages`，便于提前配置 Pages |
| `scripts/publish-release.sh` | 可选：额外归档到 GitHub Release |
| `requirements.txt` | 默认依赖清单（不填 `requirements_text` 时使用） |

## 一、首次准备

1. **推送仓库并开启 Pages**

   `gh-pages` 分支**不会**在 push 代码时出现——它由 workflow 第一次发布时创建。
   所以有两种顺序：

   *顺序 A（推荐，先跑再配）*

   ```bash
   # 手动跑一次（默认 publish_target=pages，Publish 任务成功后就出现 gh-pages）
   gh workflow run build-wheels.yml -f platforms=manylinux2014_x86_64 \
       -f python_versions=3.11
   gh run watch
   ```

   等 `Publish` 任务变绿后，Settings → Pages → **Deploy from a branch** → `gh-pages` → `/ (root)`。

   *顺序 B（先配 Pages 再构建）*

   ```bash
   bash scripts/init-pages-branch.sh    # 建一个只含占位页的 gh-pages 分支
   ```

   然后在 Settings → Pages 里选 `gh-pages`。该脚本用临时 index 生成根提交后直接推送，
   不会切换分支、不会提交你的项目文件。

   > 私有仓库的 Pages 需要付费套餐，否则请用 `publish_target=release`。
   > Pages 开启后首次部署需要几十秒，`https://<owner>.github.io/<repo>/wheels/` 才有内容。

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
| `repair` | 修复策略：`auto`（按 platforms.json）/ `auditwheel` / `none` | `auto` |

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
| `armv7l` | 树莓派 32 位 Raspberry Pi OS | Debian bookworm 基线，wheel 标签为 `linux_armv7l`；自动补 `psycopg-binary` |
| `musllinux_1_2_armv7l` | Alpine on 树莓派 32 位 | musl ≥ 1.2 |

> `manylinux2014_*` 的基线是 CentOS 7，系统库偏老（例如 libpq 9.2）。需要较新系统库才能编译的
> 包（如 `psycopg[c]`）请改用 `manylinux_2_28_*`；32 位 ARM 的 `armv7l` 是 Debian 12 基线，库比较新。
>
> `armv7l` 会自动处理仍写着 `psycopg[binary]` 的 requirements：从同版本源码构建 wheel，并把 libpq
> 及其非 glibc 依赖装进 `psycopg_binary.libs`，客户端无需改成 `psycopg[c]`。

新增平台只需在 `platforms.json` 里加一条（镜像、`docker_platform`、`qemu`、`interpreter`、
`repair`）。`ppc64le` / `s390x` 用同样的方式加 `quay.io/pypa/manylinux2014_ppc64le` 即可。

字段里的占位符：

* `{cptag}` → `cp311`（ABI 标签；镜像内目录形如 `/opt/python/cp311-cp311`，因此模板写作 `/opt/python/{cptag}-{cptag}/bin/python`）
* `{py}` → `3.11`（用于镜像 tag，例如 `arm32v7/python:{py}-bookworm`）

跨架构构建靠 **QEMU 用户态模拟**：`linux/arm64` 用 `arm64`，`linux/arm/v7` 用 `arm`。
因此 ARM 任务比原生慢（尤其要现场编译 C 扩展时），但 PyPI 上已有对应架构 wheel 的包
只是被下载并收进仓库，速度很快。

### 怎么确认目标设备该选哪个 key

在**目标设备**上执行：

```bash
python -c "import sys, sysconfig; print('arch  :', sysconfig.get_platform()); print('python:', sys.version.split()[0])"
ldd --version | head -1          # glibc 版本；Alpine（musl）没有输出，看 /etc/alpine-release
python -m pip debug --verbose | sed -n '/Compatible tags/,+4p'
```

判读规则：

* `Compatible tags` 里出现 `manylinux_2_28_aarch64` → 选 `manylinux_2_28_aarch64`；
  只要它出现，`manylinux2014_aarch64` 也一定能装（基线更老，兼容性更好，**优先选它**）。
* 出现 `musllinux_1_2_*` → 系统是 musl（Alpine 类），选对应的 musllinux key。
* 只有 `linux_armv7l`（没有 `manylinux_*`）→ 选 `armv7l`。
* 只有 `linux_x86_64` 且带 `manylinux_2_17` → 选 `manylinux2014_x86_64`。

另外两点必须对上：

1. **Python 版本**：设备的 `python` 是 3.12 → `python_versions` 里必须含 `3.12`（wheel 按 `cp312` 打标签）。
2. **glibc 不能比 wheel 基线更旧**：设备 `ldd` 报 2.39 时，2.17 / 2.28 的 wheel 都能装；
   反过来设备 2.17 装不了 2.28 基线构建出来的 wheel。

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

### 系统依赖（跨发行版包名）

`system_packages` 里**只需写一种风格**（以 Debian 的 `-dev` 命名为准），脚本按镜像里的包管理器
自动翻译：

| 你填的 | apt（Debian/Ubuntu） | yum（manylinux2014/2_28） | apk（musllinux） |
| --- | --- | --- | --- |
| `libpq-dev` | `libpq-dev` | `libpq-devel` → 回退 `postgresql-devel` | `postgresql-dev` |
| `libxml2-devel` | `libxml2-dev` | `libxml2-devel` | `libxml2-dev` |
| `libxslt-devel` | `libxslt1-dev` | `libxslt-devel` | `libxslt-dev` |
| `libssl-dev` | `libssl-dev` | `openssl-devel` | `openssl-dev` |
| `libffi-dev` | `libffi-dev` | `libffi-devel` | `libffi-dev` |
| `libyaml-dev` | `libyaml-dev` | `libyaml-devel` | `yaml-dev` |
| `libjpeg-dev` | `libjpeg-dev` | `libjpeg-turbo-devel` | `libjpeg-turbo-dev` |
| `zlib1g-dev` | `zlib1g-dev` | `zlib-devel` | `zlib-dev` |
| `build-essential` | `build-essential` | — | `build-base` |
| `pkg-config` | `pkg-config` | `pkg-config` | `pkgconf` |
| `libopenblas-dev` / `liblapack-dev` / `gfortran` | 同名 | `openblas-devel` / `lapack-devel` | `openblas-dev` / `lapack-dev` |

实现细节：先整批装一次，失败则逐包重试候选名；yum/dnf 失败时会自动带
`--disablerepo=epel` 重试（manylinux 镜像里预置的 epel metalink 基本都已失效，会让整批安装中断）。
系统依赖装不上会**直接终止**该 Python 版本，而不是让 pip 在半路报一堆找不到头文件的错。

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

**Q：publish 报「没有任何 wheel 可以发布」？**
说明 build 阶段零产出，`ignore_build_errors=true` 只是吞掉了单项失败。到 Actions 里点开对应
`Build (<platform>)` 任务，Job Summary 与日志里的 `### ❌ Python 3.x 构建失败` 会列出失败的包，
上方 `pip` 输出就是真实原因（通常是缺系统头文件、编译器或内存不足）。
> 现版本已把「一个 wheel 都没构建出来」判为硬失败，不会再出现 build 全绿、publish 才报错的情况。

**Q：`psycopg[binary]` 在 ARMv7 上装不上？**
`psycopg-binary` 官方没有发布 armv7l wheel，也没有对应的 sdist。
本仓库现在会在 `armv7l` 平台自动补一个兼容 wheel，**客户端不需要修改 requirements**：

```python
psycopg[binary]>=3.1
```

构建时自动执行以下步骤：

1. 用目标 Python 和 requirements 解析实际选中的 `psycopg` 版本（例如 3.2.13）；
2. 下载同版本的 `psycopg-c` sdist（其中已经包含生成好的 C 文件），按官方
   `copy_to_binary.py` 的规则把 `psycopg-c` 改名为 `psycopg-binary`；
3. 在 QEMU 模拟的 ARMv7 容器里从源码编译；
4. 因为 auditwheel 没有 armv7l 策略，直接把 libpq、OpenSSL、Kerberos、LDAP 等非 glibc
   动态库装进 `psycopg_binary.libs`，并把 RUNPATH 修到 wheel 内部；
5. 安装生成的 wheel，实际导入 `psycopg_binary.pq` 做冒烟测试。

随后正常的 `pip wheel -r requirements.txt` 会通过 `--find-links wheelhouse/` 命中这个本地
`psycopg_binary-*.whl`，所以设备端仍然可以直接安装 `psycopg[binary]`。目标机**不需要**
另外安装 `libpq5`。

注意：

* 这个 wheel 的平台标签是 `linux_armv7l`，以 `armv7l` 平台的 Debian 12 镜像为基线，
  因此目标系统的 glibc 也应不低于 Debian 12；glibc 更老的系统需要换成对应的自托管 runner
  或自行降级构建基线。
* 自动构建依赖 PyPI 上的 `psycopg-c` sdist。对应版本不存在或网络不可达时，
  Job Summary 会把它列为 `psycopg[binary]` 构建失败。
* 如果项目愿意改依赖，`psycopg[c]` 仍然可用，但此时目标机必须安装 libpq 运行库；自动方案
  的意义正是避免这种 requirements 和运行环境分叉。
* 设备是树莓派 4/5 这类 64 位硬件时，**换 aarch64 系统仍是更彻底的选择**：官方
  `psycopg[binary]`、numpy、pandas 都有更完整的预编译 wheel。

**Q：armv7l 上 `numpy` / `pandas` 编译失败或超时？**
32 位 ARM 上这两个包**没有预编译 wheel**（piwheels 也没有 cp312），只能现场编译，且 numpy 需要
BLAS/Fortran：

```bash
-f system_packages="gfortran libopenblas-dev liblapack-dev"
```

即便如此，QEMU 模拟下 numpy/pandas 仍可能耗时 1 小时以上甚至 OOM。更务实的做法：

* 设备上直接用发行版包：`apt install python3-numpy python3-pandas`（venv 里可用
  `--system-site-packages` 复用，或 `pip install --no-deps` 后手动补依赖）；
* 或者拆成两份 requirements：先跑纯 Python / 小体积的包验证链路，重编译包单独触发、单独调大
  `timeout-minutes`；
* 长期方案是把 `platforms.json` 里 `armv7l` 的 `runs_on` 换成自托管 ARM runner，彻底绕开 QEMU。

**Q：ARM 构建特别慢 / 超时？**
QEMU 模拟下编译 `numpy`/`scipy` 这类包可能需要几十分钟。优先确认 PyPI 是否已有该架构
wheel（有的话只是下载）；确实要现场编译时，精简 `python_versions`、减少 `platforms`，
或改用原生 ARM runner（`platforms.json` 里的 `runs_on` 换成自托管 runner 标签）。

**Q：Settings → Pages 里选不到 `gh-pages` 分支？**
这个分支要等 workflow 第一次**发布成功**才出现，push 代码不会产生它。两种解法：
跑一次 `Build Wheels`（`publish_target=pages`），或先执行 `bash scripts/init-pages-branch.sh`。

**Q：跑了 workflow 还是没有 `gh-pages`？**
依次检查：① `publish_target` 是不是 `none`；② `Publish` 任务是否被跳过——它的条件是
「build 成功，或 `ignore_build_errors=true`」；③ `Publish` 日志里 `待发布 wheel` 是否为 0
（没有 wheel 就不会建分支）；④ 仓库 Settings → Actions → Workflow permissions 是否为
**Read and write**。

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
