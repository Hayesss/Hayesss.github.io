# 测试指南：GSEA→热图动线重构

## 前置条件

### 1. 确保 R 包已安装

在 conda 环境中安装必要的包：

```bash
conda activate rna_seq_web
conda install -c conda-forge r-dplyr r-tidyr r-tibble
```

或者使用项目提供的脚本：

```bash
conda activate rna_seq_web
Rscript scripts/install_r_extra.R
```

注：GSEA dotplot 和 barplot 现在使用改进版 ggplot2 绘制，不再依赖 plotthis 包。

### 2. 启动服务

```bash
./start_fastapi.sh
```

访问 `http://localhost:8000`

## 测试步骤

### 测试 1：新的 GSEA 绘图（plotthis dotplot + barplot）

1. 提交一个新任务（或使用现有的成功任务）
2. 确保 GSEA 模块已启用
3. 任务完成后，检查 `var/jobs/{job_id}/output/` 下是否有：
   - `gsea_dotplot.png`（plotthis 版本）
   - `gsea_barplot.png`（新增）
   - `gsea_core_genes.json`

4. 在前端 GSEA 页面：
   - 输入 job_id 并加载通路
   - 使用"Dotplot"/"Barplot"按钮切换图片预览
   - 验证两张图都能正常显示

### 测试 2：就地生成热图（无新 job_id）

#### 准备工作
使用已有成功 job（例如 `452c36e0458e4d4b9e797fa625d71ccc`）或完成测试 1。

#### 前端测试
1. 打开 `#/gsea` 页面
2. 输入 job_id 并点击"加载通路"
3. 点击表格中的任意一行通路
   - 应该看到行高亮
   - 下方显示"已选择通路：xxx"
   - 出现"去热图页生成"按钮
4. 点击"去热图页生成"按钮
   - 跳转到 `#/heatmap` 页面
   - 显示当前选中的通路信息
5. 在热图页点击"生成热图"按钮
   - 等待生成完成（约 10-30 秒）
   - 成功后应显示热图预览
6. 检查 `var/jobs/{job_id}/output/` 下是否有：
   - `heatmap.png`（生成或更新）
   - `heatmap_genes.csv`

#### 后端测试（可选）
使用 curl 直接测试 inplace 接口：

```bash
JOB_ID="452c36e0458e4d4b9e797fa625d71ccc"
curl -X POST "http://localhost:8000/api/jobs/${JOB_ID}/heatmap_from_gsea_inplace" \
  -F "pathway_id=HALLMARK_ALLOGRAFT_REJECTION" \
  -F "pathway_description=HALLMARK_ALLOGRAFT_REJECTION"
```

检查响应：
- 应返回 `{"job_id": "..."}`（同一个 job_id）
- 查看 `var/jobs/${JOB_ID}/output/heatmap.png` 是否生成

查看状态：

```bash
curl "http://localhost:8000/api/jobs/${JOB_ID}"
```

检查返回的 JSON 中 `extra.heatmap_from_gsea` 字段。

### 测试 3：并发锁机制

1. 在热图页快速连续点击"生成热图"两次
2. 第二次应该返回 409 错误："热图正在生成中，请稍后再试"
3. 等待第一次生成完成后再试，应该成功

### 测试 4：错误处理

#### 场景 1：未选择通路
1. 直接访问 `#/heatmap` 页面（不先在 GSEA 页选择通路）
2. 点击"生成热图"
3. 应提示："请先到 GSEA 页面选择一个通路"

#### 场景 2：job 缺少 GSEA 输出
1. 使用一个没有运行 GSEA 的 job_id
2. 尝试生成热图
3. 应返回错误："缺少 output/gsea_results.csv"

#### 场景 3：基因不匹配
（此场景需要构造特殊数据，可跳过）

## 验证清单

- [ ] GSEA 分析生成了 dotplot 和 barplot 两张图
- [ ] 前端 GSEA 页面能切换查看两张图
- [ ] GSEA 页面行点击只选择，不触发派生任务
- [ ] 热图页面能显示当前选中的通路
- [ ] 热图生成在同一 job_id 下（不创建新 job）
- [ ] 热图生成成功后能在热图页预览
- [ ] 并发锁机制生效
- [ ] 错误提示清晰明确

## 已知问题与解决

### 问题：缺少 R 包（dplyr, tidyr, tibble）

**解决方法**：
```bash
conda activate rna_seq_web
conda install -c conda-forge r-dplyr r-tidyr r-tibble
```


## 回滚方案

如果新功能出现问题，可以使用旧版接口：

- 旧接口：`POST /api/jobs/{job_id}/heatmap_from_gsea`（创建新 job）
- 旧版前端保留在 git history 中
