# fexport

> 基于 Pandoc 的文档转换工具，支持 Markdown、RMarkdown、Quarto

[![Perl](https://img.shields.io/badge/Perl-5.20+-blue.svg)](https://www.perl.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 简介

fexport 是一个命令行文档转换工具，它封装了 Pandoc、R Markdown 和 Quarto 的功能，提供统一的转换接口。支持将 Markdown 系列文档转换为 HTML、PDF、Word 等多种格式。

### 主要特性

- 🔄 **多格式支持**: Markdown、RMarkdown (.Rmd)、Quarto (.qmd)
- 📄 **多输出格式**: HTML、PDF、DOCX、LaTeX 等
- 👀 **实时预览**: 内置 browser-sync，修改后自动刷新
- ⚙️ **灵活配置**: YAML 配置文件 + 命令行选项
- 🧠 **智能路径**: 根据输入路径类型自动判断工作目录

## 安装

### 依赖项

- Perl 5.20+
- [Pandoc](https://pandoc.org/) 2.0+
- (可选) [R](https://www.r-project.org/) - 用于 RMarkdown
- (可选) [Quarto](https://quarto.org/) - 用于 Quarto 文档
- (可选) [browser-sync](https://browsersync.io/) - 用于实时预览
- (可选) [LaTeX](https://www.latex-project.org/) - 用于 PDF 输出

### 通过 cpanm 安装

```bash
# 从本地安装
git clone https://github.com/your-username/fexport.git
cd fexport
cpanm .

# 安装 browser-sync (用于预览功能)
npm install -g browser-sync
```

### Perl 依赖模块

- Path::Tiny
- YAML::XS
- IPC::Run3
- File::ShareDir

## 快速开始

### 基本转换

```bash
# Markdown 转 HTML (默认)
fexport document.md

# 转换为 PDF 并自动打开
fexport -t pdf --open document.md

# 转换为 Word
fexport -t docx -o report.docx document.md

# 指定输出目录
fexport -t pdf -d ./output document.md
```

### 使用实时预览

```bash
# 启动预览服务器并打开浏览器
fexport --preview document.md

# 修改文档后重新转换，浏览器自动刷新
fexport document.md

# 停止预览服务器
fexport --stop-preview
```

### RMarkdown 和 Quarto

```bash
# 转换 RMarkdown
fexport analysis.Rmd
fexport -t pdf analysis.Rmd

# 转换 Quarto
fexport paper.qmd
fexport -t pdf paper.qmd
```

## 命令行选项

| 选项 | 简写 | 说明 |
|------|------|------|
| `--to` | `-t` | 输出格式 (html, pdf, docx, latex) |
| `--from` | `-f` | 输入格式 (md, rmd, qmd)，自动检测 |
| `--outfile` | `-o` | 输出文件名 |
| `--outdir` | `-d` | 输出目录 |
| `--workdir` | | 工作目录 |
| `--config` | `-c` | YAML 配置文件 |
| `--pandoc` | `-p` | 传递额外选项给 Pandoc |
| `--lang` | | 文档语言 (zh, en) |
| `--verbose` | `-v` | 详细输出模式 |
| `--keep` | `-k` | 保留中间文件 |
| `--preview` | | 启用实时预览 |
| `--stop-preview` | | 停止预览服务器 |
| `--browser` | | 指定预览浏览器 |
| `--open` | | 自动打开生成的文件 |
| `--help` | `-h` | 显示帮助信息 |

## 配置文件

可以创建 YAML 配置文件来自定义默认行为。

### 配置文件示例

```yaml
# ~/.fexport.yaml
to: pdf
lang: zh

pandoc:
  cmd: "pandoc +RTS -M512M -RTS"
  
  # Markdown 格式扩展
  markdown-fmt:
    - markdown
    - emoji
    - east_asian_line_breaks
  
  # Pandoc 过滤器
  filters:
    - "--citeproc"
    - "--lua-filter=my-filter.lua"
  
  # 额外选项
  user-opts:
    - "-V"
    - "geometry:margin=1in"
```

### 使用配置文件

```bash
fexport -c ~/.fexport.yaml document.md
```

### 默认配置

程序内置的默认配置位于 `lib/Fexport/Defaults.pm`，包含：

- 默认输出格式: HTML
- 默认语言: 中文 (zh)
- Pandoc Markdown 扩展
- 常用过滤器配置

## 工作目录逻辑

fexport 会根据输入文件路径自动判断工作目录：

| 输入路径类型 | 工作目录 | 示例 |
|-------------|---------|------|
| 绝对路径 | 文件所在目录 | `/home/user/docs/file.md` → `/home/user/docs/` |
| 相对路径 | 当前目录 | `docs/file.md` → `./` |

可以使用 `--workdir` 显式指定工作目录。

## 预览功能

预览功能使用 [browser-sync](https://browsersync.io/) 实现，支持：

- 🌐 自动打开浏览器
- 🔄 文件变更时自动刷新
- 🖥️ 多设备同步预览

```bash
# 安装 browser-sync
npm install -g browser-sync

# 使用预览
fexport --preview document.md

# 指定浏览器
fexport --preview --browser=firefox document.md

# 查看运行中的预览服务
ps aux | grep browser-sync

# 停止所有预览
fexport --stop-preview
```

## PDF 输出

PDF 输出需要安装 LaTeX 环境。推荐使用 TeX Live:

```bash
# Arch Linux
sudo pacman -S texlive-core texlive-xetex

# Ubuntu/Debian
sudo apt install texlive-xetex texlive-fonts-recommended

# macOS
brew install --cask mactex
```

### 调试 PDF 问题

使用 `--keep` 保留中间文件：

```bash
fexport -t pdf --keep document.md
# 中间文件保存在: /tmp/xxx/
```

## 项目结构

```
fexport/
├── script/
│   └── fexport           # 主程序
├── lib/
│   └── Fexport/
│       ├── Config.pm     # 配置管理
│       ├── Converter.pm  # 格式转换
│       ├── Defaults.pm   # 默认配置
│       ├── Pandoc.pm     # Pandoc 命令构建
│       ├── Quarto.pm     # Quarto 处理
│       ├── Rmd.pm        # RMarkdown 处理
│       ├── Util.pm       # 工具函数
│       └── PostProcess.pm # 后处理
├── share/
├── t/                    # 测试文件
└── Makefile.PL          # 安装脚本
```

## 开发

### 运行测试

```bash
prove -l t/
```

### 从源码运行

```bash
perl -Ilib script/fexport --help
```

## 常见问题

### Q: PDF 转换报错 "Option clash for package babel"

这是 LaTeX 包冲突。检查你的 Pandoc 模板或 header 文件中的 babel 配置。

### Q: 预览功能不工作

确保已安装 browser-sync：

```bash
npm install -g browser-sync
which browser-sync
```

### Q: RMarkdown 转换失败

确保已安装 R 和 rmarkdown 包：

```r
install.packages("rmarkdown")
```

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！
