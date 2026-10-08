# AGENTS.md

本文件记录**通用工程规则**。它们来自 `doc/F3-SVG图标方案.md` §22 那次
FPC-8 兼容层实验的实测结果，而不是任何外部路线图的要求，也不是把那次实验的
具体结论提升为整个项目的兼容性规范。

适用范围：本仓库内所有代码与文档改动。

---

## 1. FPC 没有 Delphi 式的 transitive interface visibility

**实测事实**：一个只写了 `uses Forms;` 的 FPC 单元**不会**把 `Forms` 的符号
继续 re-export 给自己的使用者：

```pascal
unit Vcl.Forms;
interface
  uses Forms;          { 这不够 }
implementation
end.
```
```
t.pas(4,8) Error: Identifier not found "TForm"
```

因此任何兼容层 / shim / facade 重导出必须按符号类别显式处理：

| 类别 | 可行做法 |
|---|---|
| **type** | 显式别名（`TVirtualImage = TLclVirtualImage;`） |
| **routine** | 必须显式重新声明，并**保持 external binding**（`external 'dll' name '...'`） |
| **var / const** | 必须显式 redeclare |

**不得假设** `interface uses X` 能把 X 的符号转发出去。**不存在 forwarding
shortcut。**

⚠️ 附带一个易被忽略的陷阱：子类**不是**别名。
`TVirtualImage = class(TLclVirtualImage)` 与 `TVirtualImage = TLclVirtualImage`
在类型上是**两个不同的类型**，会让 DFM/LFM 流式化赋值变成编译错误。

---

## 2. 可归因变更：一次只引入一个有意义的变量

做 before/after measurement 时：

- **一次只改一个有意义的变量。**
- 避免多个改动同时发生，否则 ratchet 的移动无法归因。
- 增长与下降都**不自动接受**：基线变更必须是显式动作，因为工具误算一次就会
  诱发"顺手把基线改小"的坏习惯。
- **测量与行动方案分开归档。** 测量事实不被重写；被证伪的行动方案可以
  supersede 并注明取代关系。这一条在 §20 → §21 → §22 中被实际使用过。

---

## 3. 任何能授权"不做这部分工作"的 classifier，必须测试**危险失败方向**

如果某个 classifier / gate / 分析工具的输出，可能成为"**因此这部分工作不必做**"
的依据，那么它必须验证**错误方向**，而不仅仅是 happy path。

理由：happy path 全绿**不能**证明分类正确。§22 那次实验里，一个 happy-path 绿的工具
把 `System.SysUtils` 判成"未被使用、可删除"——而真实原因是提取器失败
（FPC 的 RTL 单元是 `{$I *.inc}` 空壳）。**这是本类工具唯一不可犯的错误方向**：
其余方向的误判只浪费时间，这一方向的误判会**批准删除真实工作**。

配套做法：

- 证据提取失败**不等于**符号不存在；无法枚举时报告 **INDETERMINATE**，不猜。
- 有歧义的解析（例如平台条件化的 `{$I}`）应**拒绝判定**，而不是"取第一个命中"——
  取错会注入另一个平台的声明，并把它当作证据。
- **INDETERMINATE 是正式结果，不是缺口。** 保留未知，好过为了让表格完整而猜。

---

## 提交状态约定

- 门禁"通过"必须包含**可失败性**证明：逐条破坏并确认被捕获，且**为自己的理由**被捕获。
- 若一个 gate 的 `MISSED` 路径打印不出证据行，该 harness 就是有缺陷的——
  空断言看起来和通过一样。