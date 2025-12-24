# GPU Monitor 用户级显卡监控系统
## 项目简介
本项目基于 Prometheus + Grafana 实现了对多台服务器 GPU 使用情况的实时监控和统计，支持用户级别的显卡资源占用分析、历史使用时长排行、负载与温度趋势展示等。适用于 AI 算力集群、深度学习服务器等场景。

## 功能特性
🖥️ 在线显卡总数统计
👥 当前活跃用户数量
⚡ 集群 GPU 平均负载
🔥 最高温度监控
🏆 用户使用时长排行榜（近1天/1周/1月）
📊 用户/空闲占比饼图（近1天/1周/1月）
🕵️ 深度监管列表（显存占用、核心负载、总显存、占用率等）
⚙️ 显卡实时负载与温度趋势图
支持多用户、多服务器筛选
Grafana 仪表盘美观易用，支持自定义筛选和排序

# 部署步骤
## 环境准备
- 服务器已安装 Docker 和 docker-compose
- 已部署 Prometheus 采集 GPU 指标（如 nvidia-dcgm-exporter）

## 克隆项目
`
git clone http://suncore946/gpu_monitor.git
cd gpu_monitor
`

## 启动服务
`
docker compose up -d
`

## 导入 Grafana 仪表盘
- 登录 Grafana
- 新建仪表盘，导入 grafana.json
- 配置 Prometheus 数据源（变量名为 DS_PROMETHEUS）

## 自定义变量
- 支持按用户、服务器 IP 过滤和统计
- 可自定义时间范围（默认近30天）

## 使用说明
- 打开 Grafana 仪表盘，选择数据源和筛选条件
- 查看各类统计面板，支持排序、筛选、导出
- 用户排行榜和占比饼图可帮助管理员优化资源分配
- 深度监管列表可快速定位“僵尸进程”或长期占用者

## 文件说明
- collect_gpu_user.sh：采集 GPU 用户信息的脚本（可选）
- docker-compose.yml：一键部署 Prometheus/Grafana 服务
- gpu_test.py：GPU 采集测试脚本
- grafana.json：Grafana 仪表盘配置文件
- README.md：项目说明文档

# 常见问题
## Grafana 无法显示数据？
- 检查 Prometheus 数据源配置和采集端点
- 确认 GPU 监控 exporter 正常运行

## 用户信息不准确？
- 需保证 GPU exporter 能采集到进程用户信息
- 如何扩展支持更多服务器？

## 在 Prometheus 配置中添加新服务器的 scrape job
- Grafana 仪表盘自动支持多实例筛选