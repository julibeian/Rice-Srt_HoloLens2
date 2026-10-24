# 参与项目

项目组可以从资料收集、实验设计、样本整理和代码改进四个方向参与。记录应能帮助其他成员判断问题、复现实验或复用资料。

## 提交资料

使用“资料收集”Issue 模板，说明来源、适用模块、可用内容和使用限制。经讨论后，把条目补到 [资料库](resources/README.md)，较完整的阅读笔记使用 [资料条目模板](resources/templates/resource.md)。已有相同来源时补充原条目。

文献保留作者、发表年份、DOI 或稳定链接；数据集保留许可、标注方式和划分说明。图片与代码的署名和许可证随资源一起保留。

## 提交实验

先选用或补充 [实验协议](experiments/protocols/leaf-capture.md)，再使用“实验记录”Issue。结论按实验编号、应用版本、样本批次和条件组织，正文使用 [实验报告模板](experiments/templates/report.md)。

把观察结果、解释和待验证项分别写清。失败、拒识和缺失数据也是实验结果；采样不足时说明范围。原图与敏感环境信息保存在约定的受控资料位置，仓库登记批次引用、摘要和文件哈希。

## 修改代码

1. 用 Issue 说明问题或预期行为，再建立功能分支。
2. 提交聚焦的改动，按 [开发指南](docs/development.md) 运行相关检查。
3. Pull Request 写明变化、验证结果和限制；涉及实验结论时链接对应报告。
4. 发布版本更新 `CHANGELOG.md` 和 `releases/<版本>/manifest.json`；重要架构变化同步更新 [技术决策](docs/decisions.md)。

团队协作以议题、实验结论和版本交付为单位。报告保留可复现方法、结果和限制，执行细节随实验原始资料管理。

## 提交前检查

```powershell
node field-app/build.mjs
node --test field-app/tests/*.test.cjs
python tools/Verify-Product.py
git add <本次改动的路径>
python tools/Check-Repository.py
```

设备配置、口令、令牌、配对材料和原始运行日志不进入 Git。模板中的示例是填写说明，不能作为已完成实验引用。
