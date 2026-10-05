# Repository Guidelines

## 项目结构与模块职责

本项目是支持 Zabbix 4.0–7.x 的 Ruby Gem，要求 Ruby 3.4 及以上；CI 使用 Ruby 3.4 和 4.0。

- `lib/zabbix_manager.rb`：公共入口；`lib/zabbix_manager/`：配置、客户端、HTTP 传输、日志脱敏及流量查询。
- `lib/zabbix_manager/classes/`：原生 API 资源封装；`monitoring/`：设备、线路及阈值管理流程。
- `spec/`：RSpec 测试；`spec/support/`：原生 API 测试夹具。
- `examples/`：调用示例；`README.md`、`CHANGELOG.md`：接口说明与变更记录。
- `script/verify_package.rb`：打包验证；`pkg/`、`doc/`：构建与文档产物。

监控功能使用原生 Zabbix API，不依赖 Rails、数据库模型或 SQL。

## 安装、开发与验证命令

在仓库根目录执行：

- `bash bin/setup`：安装 Bundler 依赖。
- `bundle exec ruby bin/console`：启动已加载本库的 IRB。
- `bundle exec rspec`：运行全部测试；可追加路径执行单个文件，例如 `spec/zabbix_manager/client_spec.rb`。
- `bundle exec rake`：执行 RSpec、RuboCop 和 Yardstick 文档覆盖率检查。
- `bundle exec rubocop`：单独检查格式、静态规则、性能与打包规范。
- `bundle exec ruby script/verify_package.rb`：构建 Gem，隔离安装并通过本地 HTTP 请求验证，保存产物到 `pkg/`。
- `git diff --check`：检查差异中的空白错误。

## 编码风格与命名

使用两空格缩进，行长不超过 120 字符；Ruby 文件保留 `# frozen_string_literal: true`。以 `.rubocop.yml` 为准。类名采用 `CamelCase`，文件、方法和资源访问器使用 `snake_case`，例如 `host_groups`。沿用关键字参数接口，为公共方法补充 YARD 参数、返回值和异常说明。修改依赖时同步锁文件并运行完整门禁。

## 测试要求

测试命名为 `*_spec.rb`，目录尽量对应 `lib/` 中的模块。新增功能补充行为测试，修复缺陷增加回归测试。复用 API 夹具、RSpec doubles 或本地 socket 服务，避免依赖生产 Zabbix。覆盖版本差异、输入校验、资源归属及写入结果不确定等边界。

当前未设置测试覆盖率百分比门槛；Yardstick 的文档覆盖率门槛为 67.1%。提交前执行完整门禁和打包验证。

## 提交与 Pull Request

从 `master` 创建工作分支。近期提交使用简短中文动词描述，例如“修复资源身份与监控预检边界”；历史没有统一的 Conventional Commits 要求。一次提交聚焦一个目的，避免混入 IDE 文件、构建产物或无关改动。

PR 应说明问题、行为变化、关联 issue（如有）及实际验证命令与结果。接口变化同步更新 README、示例和变更记录，并确保 CI 通过。

## 配置与安全

通过环境变量或秘密存储提供 `ZABBIX_URL`、`ZABBIX_API_TOKEN` 等配置。保持 TLS 校验开启，不提交或记录真实密码、令牌及 SNMP 凭据。对结果不确定的写请求先核实远端状态，再决定是否重试。
