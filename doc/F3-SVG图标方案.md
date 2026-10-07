# F3-SVG：LCL 矢量图标方案

> 生成日期：2026-10-04
> 数据来源：`tools/f3_svg_inventory.py` 实测（非估算）
> 关联：[[FPC-Lazarus渐进式移植实施方案]] §3 F3/F4

---

## 1. 为什么这是当前唯一的架构杠杆

实测发现（见实施方案 §8.6）：**9 个 A 批窗体转换后窗口能开、但图标全空**，另有 4 个 C 批窗体被同一原因阻塞。它们全部依赖 vendored 的 `TSVGIconImageList`。

| 事实 | 实测值 |
|---|---|
| 依赖 SVG 图标的窗体 | **15**（A 批 9 + C 批 6） |
| 其中原本被误判为「已完成」 | **9** |
| `.Images` 赋值点总数 | 97 |
| 其中指向 SVG 列表 | **70**（其余走既有 `TImageList`，不受影响） |

**结论：SVG 一次解锁 13 个窗体**，是当前唯一能改变 F3 排期的动作。

---

## 2. 数据实测：远比预想的轻

| 项 | 实测值 |
|---|---|
| SVG 图像列表 | 5 个（`SVGImageListMenuStyle` / `ProjectStyle` / `ClassStyle` / `MessageStyle` / `IconImageWelcomeScreen`） |
| 图标条目 | **116 条**（94 个不重名，20 个名字重复） |
| SVG 文本总量 | **约 88.6 KB**（116 条，最大单条 4.2 KB） |
| 数据位置 | **DFM 内联**（`SVGText = '<svg .../>'` 属性） |
| 外部依赖 | **零** —— 无 `<image>`、无 `xlink:href`、无 `@font-face`、无 `url()` |

### 这个事实改变了方案选择

因为图标是**自包含的内联文本**：

- ✅ **不存在**文件路径解析问题（无需资源打包/复制）
- ✅ **不存在**对 `fpvectorial` / `lazutils` XML 光栅化链的运行时依赖
- ✅ **数据完全不需要搬动** —— 它已经在 DFM 里
- ⚠️ 唯一与 VCL 耦合的是**控件**（`TSVGIconImageList` 派生自 `TCustomImageList`），不是数据

> **所以问题不是「LCL 能否加载这些 SVG」，而是「用什么把内联 SVG 画到 TCanvas 上」。**

---

## 3. 替换面（必须暴露的 API）

| API | 使用点 | 说明 |
|---|---|---|
| `Images` 属性 | DFM 97 处 / 代码 52 处 | 赋一个图像列表 |
| `ImageIndex` 属性 | **DFM 188 处** / 代码 48 处 | 按索引取图 |
| 索引图像列表 | 116 项 | 需支持 `GetImage`/`SetImage`/`Count` |
| 主题着色 | — | SVG 带 `fill:#7daca8` 等样式，主题切换时需运行时改色 |
| 尺寸缩放 | — | 源图标 `viewBox="0 0 18 18"`，需支持高 DPI 缩放（F4 目标：工具栏 200%/4K 清晰） |
| **每列表独立尺寸** | 5 个列表 | **实测 `Size` 属性是像素边长而非条目数**：19 / 18 / 32(默认) / 25 / 37 px。控件必须按列表尺寸渲染，不能硬编码 |

---

## 4. 方案对比

### 方案 A：移植 vendored `SVGIconImageList`（**不推荐**）

- 该库基于 **Delphi 图形 API + 第三方 SVG 解析器**（`fmx` / `fpvectorial`）
- 在 LCL 下需要重写整个渲染后端
- **且它解决不了数据问题**——数据本来就在 DFM 里，移植库只是搬了个控件壳

### 方案 B：LCL 原生 SVG 渲染控件（**推荐**）

Lazarus 自带 `lazutils` 图形栈与 **`TSVGComponent`/`TSVGImage`**（基于 `fpvectorial`，FCL/LCL 内建）。因此：

```
新控件 TLclSvgImageList = class(TCustomImageList)
  ├─ SVGText: array of AnsiString     // 内联文本，逐项
  ├─ GetImage(i)  → TBitmap           // 首次访问时按需光栅化并缓存
  ├─ 按目标尺寸缓存（Key = (index, w, h, theme)）
  └─ 主题变更时清缓存
```

**优势**：
1. **零数据迁移** —— SVG 文本仍在原 DFM 位置
2. 复用 LCL 内建 SVG 栈，不引入新依赖
3. 按需 + 缓存光栅化：116 个图标只在真正显示时才付出代价
4. 尺寸化缓存直接服务 F4 的「200%/4K 清晰」目标

**代价**：一个约 300–400 行的控件 + 一个把 DFM 的 `SVGIconItems` 转成 `SVGText[]` 的转换步骤。

---

## 5. 实施顺序

| 步 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| 1 | **数据抽取**：从 `DataFrm.dfm` 导出 116 条 SVG → `SvgData.pas` | 可校验的常量单元 | 无 |
| 2 | **`TLclSvgImageList`**：按需光栅化 + 尺寸/主题缓存 | LCL 控件 | 步 1 |
| 3 | **DFM 转换规则**：`TSVGIconImageList` → `TLclSvgImageList`，`SVGIconItems` → `SVGText[]` | 转换器规则 | 步 2 |
| 4 | **接入 A-svg 9 个 + C 批 4 个** | 13 个窗体解锁 | 步 3 |

**关键：步 1 是纯数据搬运，可在无 Lazarus 环境下完成并校验**（比对导出的 SVG 与 DFM 原文逐字节一致）。因此即使本机装不上 Lazarus，方案也能推进到「数据就绪 + 控件代码就绪」，只差真实渲染验证。

---

## 6. 与 F4 的关系

原方案把 F3（窗体转换）与 F4（矢量图标 + 深色主题）视为独立阶段。实测证明：

- **F4 的「矢量图标：LCL 原生 SVG」正是本方案的本体**
- F3 的 13 个窗体等待它
- F4 的深色主题需要图标可运行时改色（`fill` 样式替换），与本方案缓存策略同源

> **建议：把本方案作为 F3-C 的前置，同时它就是 F4 的第一项。两个「阶段」实为同一件事的先后两面。**

---

## 7. 诚实的边界

以下**尚未验证**，不得当作已完成（**2026-10-05 已更新，见 §11**：本机现已能真实编译，三项中两项已有结论）：

- ❌ ~~**LCL 的 `TSVGComponent` 能否处理这些 SVG 的具体子集**~~ —— **该前提本身是错的**：`fpvectorial.pas` 中 `TSVG\w*` **零命中**，根本没有这个类。真实入口是 `TvVectorialDocument.ReadFromStream(S, vfSVG)` + `TvPage.Render(Canvas, …)`。实测见 §11.2
- ❌ **主题改色的具体实现** —— SVG 用 `style="fill:#7daca8"`，需确认改写策略（字符串替换 vs CSS 类）
- ❌ **188 处 `ImageIndex` 的取值是否都在列表范围内** —— 需在控件实现后由运行时校验
- ❌ **116 个图标在高 DPI 下的光栅化质量** —— F4 明确要求 200%/4K 清晰

**外部条件已于 2026-10-05 解除**：`C:\lazarus` 下已可用，且本机成功编译了 LCL 与 fpvectorial 两个包（见 §11.1）。此前"本机无 FPC/Lazarus"的记录已过期。

---

## 11. 首次真实编译：修正了方案里 4 处错误前提（2026-10-05）

本节记录把本方案从"纸面设计"变成"可编译"的过程。**结论先行：§2/§4 关于 LCL API 的三处描述都是错的，而 §1 的产物 `SvgData.pas` 根本编不过。** 所有结论均为实测，非阅读文档所得。

### 11.1 先决条件：LCL 与 fpvectorial 必须**先编译**

装好的 Lazarus **只带源码，不带已编译单元**——`lcl\units\` 下只有 Lazarus IDE 自身的 288 个单元，`graphics.ppu` / `imglist.ppu` / `fpvectorial.ppu` **一个都没有**。两次 `lazbuild`（均 exit 0）后才有：

```
lazbuild --ws=win32 C:\lazarus\lcl\interfaces\lcl.lpk          # LCL
lazbuild C:\lazarus\components\fpvectorial\fpvectorialpkg.lpk  # fpvectorial
```

**在此之前，`TLclSvgImageList` 不只是"没编译过"，而是**不可能编译**。固定的搜索路径见 `tools/build_svg_probe.ps1`。

### 11.2 实测修正：LCL 与 fpvectorial 的真实 API

| §2/§4 的写法 | 实测 | 证据 |
|---|---|---|
| `TSVGComponent` / `TSVGImage`（"FCL/LCL 内建"） | **不存在**，`fpvectorial.pas` 中 `TSVG\w*` 零命中 | 全文检索 |
| `class(TCustomImageList)` + `GetImage(i)→TBitmap` override | **编不过**：`There is no method in an ancestor class to be overridden: "GetImage"`（`SetImage`、`GetCount` 同） | 编译器 |
| 按需光栅化（override 取图） | **不可行**：LCL 的 `GetCount` 是 **private 且非 virtual**，`Count` 读内部 resolution 列表 | `lcl/imglist.pp:302,403` |

LCL 里所有控件的 `Images` 属性都是 `TCustomImageList`（`TBitBtn`/`TSpeedButton`/`TImage`/`TToolBar`…），而现控件是 `TLclSvgImageList = class`——**它永远无法赋给任何 `.Images`**，也无法作为 LFM 组件流式加载。**§4 的控件设计需要重做**：正确形态是 `class(TCustomImageList)` + 用 `Add(Bitmap, nil)` 填充真实位图，代价是放弃"按需"、改为整表光栅化。

真实调用链（实测可用）：

```pascal
uses fpvectorial, svgvectorialreader, fpvectorial2canvas, Interfaces;
Doc := TvVectorialDocument.Create;
Doc.ReadFromStream(Utf8Stream, vfSVG);
Page := Doc.GetPageAsVectorial(0);
Page.Render(Canvas, 0, 0, 1.0, 1.0);
```

三个"沉默的坑"：`svgvectorialreader`（注册 SVG reader，缺则 `Unsupported vector graphics format`）、`fpvectorial2canvas`（注册默认渲染器）、`Interfaces`（LCL widgetset，缺则 `EAccessViolation`）；以及 **UTF-8 字节流**——用 `TStringStream` 在 `-Mdelphiunicode` 下喂进 UTF-16，解析器报 `EXMLReadError … invalid character 0`。

### 11.3 §1 的产物 `SvgData.pas` **编不过**（已修）

原生成器输出的是 record 常量：

```pascal
const
  SVG_IMAGE_LISTS: array[0..4] of TSvgImageList = (
    ( Name: 'SVGImageListMenuStyle';
      Names: array[0..84] of string = ( … ) ) … );
```

Delphi 合法，FPC 直接拒绝：`SvgData.pas(32,14) Fatal: Syntax error, "(" expected but "ARRAY" found`。**数据单元是控件与全部 13 个窗体的地基，而它从来没被编译过。**

实测各种形态（FPC 3.2.2）后改为**独立的静态数组常量 + `var` 记录数组在 `initialization` 填充**。另有两条 FPC 专属要求：数组元素间**必须有逗号**（Delphi 允许换行分隔，FPC 不允许），且**最后一个元素后不能有逗号**。

修完：`--verify` 仍报 **116 条 SVG 与 DFM 逐字节一致**，且 `SvgDataProbe.exe` 运行确认 **5 个列表 / 116 条载荷全部送达**，尺寸 19/18/未声明/25/37 与 `FindSvgListIndex` 均正确。

> 顺带修掉一处**锚错了对象的校验**：原 `--verify` 靠 grep 字面量 `SizePx: 19;` 来确认像素边长已写入，而这个字面量的存在只取决于"用 record 常量"这个排版选择。现在改成调用与生成器**同一个** `init_call()`，校验与写入无法各行其是。

### 11.4 实测：116 个图标中 **109 个真的画出了像素**

`RasterProbe.exe`（真 LCL + fpvectorial，198 行）**逐个光栅化并统计非透明像素**——只"解析成功"不算数，本项目已经两次栽在"结构完好但什么都不画"上：

```
SVGImageListMenuStyle      edge=19   83/ 85 ok  (0 blank)
SVGImageListProjectStyle   edge=18    6/  6 ok  (0 blank)
SVGImageListClassStyle     edge=32    7/ 12 ok  (0 blank)
SVGImageListMessageStyle   edge=25    7/  7 ok  (0 blank)
SVGIconImageWelcomeScreen  edge=37    6/  6 ok  (0 blank)
icons total : 116    rendered ok : 109    blank : 0    elapsed : 265 ms
```

**7 个失败**，症状一致（`EZeroDivide: Floating point division by zero`），已逐一定位到名称：

| 列表 | 失败索引 | 名称 |
|---|---|---|
| `SVGImageListMenuStyle` | 53 / 75 | `iconsnew-56` / `iconsnew-82` |
| `SVGImageListClassStyle` | 2 / 3 / 4 / 9 / 11 | `iconsnew-54/55/56/57/63` |

### 11.4b 根因已查明并修复：零弦弧段（2026-10-06 实测闭环）

> 上一节这条“尚未查明”在 2026-10-06 关闭。原判断有两处错误，均已在下面纠正：**症状阶段写错**（不是渲染期），以及**曾有一个回读 `SvgData.pas` 的脚本报出 85 条列表 696 条项——那个脚本本身是错的**，其对 `viewBox`/`path` 的任何结论都不作数。这条保留，因为它说明了为什么后面改用“走路径语法”的检测器而不是再写一个正则。

**根因**：7 个失败图标**每一个**、且**只有它们**含有“起终点相同”的弧段。fpvectorial 按 SVG 实现说明做端点→圆心参数化（`fpvutils.pas:550`）：

```pascal
m := (sqr(rx*ry) - sqr(rx*y1p) - sqr(ry*x1p)) / (sqr(rx*y1p) + sqr(ry*x1p));
```

零弦时 `x1p = y1p = 0` → 分母 **0**、分子 `(rx*ry)^2 > 0`；而这句除法在下一行 `SameValue` 守卫**之前**执行，守卫救不了它。

**候选筛选**（`tools/f3_svg_divzero.py`）：18 个文本形状候选**无一能分离**（最好的只到“7 个失败里都有，但全集也有”，那证明不了任何事）。改成**走路径语法**的结构候选后：

```
zero-chord-arc      7        7  PERFECT SEPARATOR
zero-radius-arc     0        0  rejected: in no failure
```

**阶段纠正（原记录是推断，不是测量）**：原文写“`EZeroDivide` 发生在渲染而非解析”，那只是从 RasterProbe 单一 try/except 推出来的。新增 `SvgParse.lpr`（**只 `ReadFromStream`，不渲染**）实测 **7/7 在解析期抛出**。因此修复必须落在“喂给解析器之前”。

**A/B 实验**（Python 生成变体、Pascal 判定，判定器不接触生成器内部）：

| 运行 | 结果 | 说明 |
|---|---|---|
| `SvgParse svg\failed` | **7/7 抛 `EZeroDivide`** | 故障在解析期 |
| `SvgTry svg\failed` | 0/7 | 基线：判定器能判负 |
| `SvgTry svg\control` | **3/3 通过** | **判定器不瞎**（3 个未改动的好图标） |
| `SvgTry svg\zerochord` | **7/7 通过且有像素** | 剔除退化弧段后全部渲染 |

变体由 `tools/f3_svg_zerochord.py` 生成，写盘前断言四条：**恰好 7/116 改变**、**与 RasterProbe 的失败名单逐名吻合**（Pascal 侧独立产出的名单）、**重建结果 = 原 token 序列减去被删组**、**输出纯 ASCII**。

> **判定器自身有个真 bug，一并留档**：`SvgTry`/首版探针把**文件路径**当 SVG 内容喂给解析器（`TEncoding.UTF8.GetBytes(AFile)`），**从未读过文件**——对任何输入都返回 0。是 `SvgParse` 首跑报 `EXMLReadError "Illegal at document level"`（报的是**参数**，不是 SVG）才暴露的。**一个对正确文件也给 0 分的判定器，会把修好的东西判成“没修好”**；`control` 目录就是为今后区分“全坏”与“判定器瞎”而设的。

**修复落点：控件，不是数据。** `LclSvgImageList.Rasterise` 在 `ReadFromStream` 前调用新增的 `StripDegenerateArcs`；`SvgData.pas` **一字未动**——`f3_svg_extract.py --verify` 仍报 **116 条逐字节一致**，那条不变式（本项目靠它抓过两次数据丢失）保持原样。

**两个独立实现必须互相校验**：新增 `SvgNorm.lpr`，把 FPC 版输出与 Python 版写盘的 7 个变体**逐字节比对** → **7/7 MATCH**。

> **首版 Pascal 实现被这道校验当场抓下**：数词切分允许消费多个小数点，把 `-.08.38` 并成**一个** token，`Val` 失败后跳字符 → 参数错位 → **漏检 6 段、伪造 4 段**，`SvgListProbe` 的失败数从 7 反升到 **11**。修法是“每个数词至多一个小数点”，并把“无法安全切分”改为**返回原文不改**（fail-safe）。**两套实现照同一份描述各写一遍、互相比较，比各自与自己比较有用得多。**

**修复后实测**：

| 项 | 修复前 | 修复后 |
|---|---|---|
| `SvgListProbe` 五个列表计数 | 83/85 · 6/6 · 7/12 · 7/7 · 6/6 | **85/85 · 6/6 · 12/12 · 7/7 · 6/6** |
| `SvgListProbe` 渲染失败 | 7 | **0** |
| `EXPECTED_MAX_FAILURES` | 7（“已知缺口”天花板） | **0**（回归即失败，该检查同时由 no-op 改为 `Inc(Failures)`） |
| `RasterProbe`（绕过控件，直接读数据） | 7 | **仍为 7 —— 符合设计**：它回答“数据能否被 fpvectorial 直接吃下”，控件回答“控件能否显示” |
| `f3_svg_extract --verify` | 116 逐字节 | **116 逐字节（未受影响）** |

**删除的代价，实测而非估计**：19 段退化弧，半径 **0.050–0.100 user units**，按各自列表边长折算**最大 0.142 px**——任何列表尺寸下都是亚像素；**19 段的 large-arc 全为 0**（(0,1)×12、(0,0)×7），因此“端点相同 + large-arc=1 可能画整圆”的那条规范解读**不适用于本次删除的任何一段**。

> **仍然不猜的一条**：SVG 规范对“端点相同”的**逐字原文**本次没有取到（W3C 页面抓取被截断），故不引用、不复述。上面所有结论都来自**可复跑的实测**；规范措辞若日后取到，再补引文。

### 11.5 步骤 2/3/4 的真实状态

| 步 | 状态 |
|---|---|
| 1 数据抽取 | ✅ **已可编译并经运行时验证**（116 条送达；`--verify` 仍逐字节）。覆盖面缺口见 §12.6 |
| 2 `TLclSvgImageList` | ✅ **编译运行通过，且 7 个 `EZeroDivide` 已修复** —— 走控件 **116/116**、`fail=0`（§11.4b） |
| 3 DFM 转换规则 | ✅ **完成**，且**首次被真实 LCL 加载验证**（§12.7） |
| 4 接入 13 个窗体 | ✅ 消费端完成；生产端 1/3，另两个被**明确拒绝**并记录原因（§12.6） |

### 11.6 步骤 2 完成：控件能真正当图像列表用了

重写后的 `TLclSvgImageList = class(TCustomImageList)`，编译 + 运行验证（`SvgListProbe.exe`）。

> **下图是修复前的读数**（`fail` 合计 7）。2026-10-06 之后同一探针报 **85/85 · 6/6 · 12/12 · 7/7 · 6/6，`fail=0`**，见 §11.4b；这里保留原读数，因为它正是“渲染失败 7 个”的当时证据。

```
SVGImageListMenuStyle     count= 83/ 85 edge=19 ink[0]= 361 fail=2
SVGImageListProjectStyle  count=  6/  6 edge=18 ink[0]= 324 fail=0
SVGImageListClassStyle    count=  7/ 12 edge=32 ink[0]=1024 fail=5
SVGImageListMessageStyle  count=  7/  7 edge=25 ink[0]= 625 fail=0
SVGIconImageWelcomeScreen count=  6/  6 edge=37 ink[0]=1369 fail=0
before theme: count=83 gen=1   →   after theme: count=83 gen=2
RESULT: SVG list works as a real LCL image list
```

验证的是三件旧设计**做不到**的事：`B.Images := L` 能赋给真实 LCL 控件（`TBitBtn`）、`Count`/边长来自数据、`GetBitmap` 取回的图标**有可见像素**。主题切换重渲染后 `Count` 不变、生成计数递增。

> 放弃"按需光栅化"是**被实测逼出来的取舍**：`GetCount` 是 private 非 virtual，per-index hook 无法存在。代价已实测：116 个图标整表光栅化 265 ms。

### 11.7 ⚠️ 需要决策：步骤 3 的产物该放哪里

> **已于 2026-10-06 关闭，选 (b)。** 决策与实测结果见 §12。

步骤 3 的转换规则要产出 `TSVGIconImageList` → `TLclSvgImageList` 的 LFM。但控件目前**放在 `Tests/FpcCoreTests/svg/` 下**，而转换后的 LFM 在 `Tests/FpcCoreTests/lfm/`。两条路：

- **(a) 留在 `Tests/`** — 控件继续作为 F3 的验证装置，不进 `Source/`。代价：将来 `Source/Fpc` 真正建 LCL 工程时要再搬一次。
- **(b) 移进 `Source/`**（如 `Source/Fpc/UI/Controls/LclSvgImageList.pas`）— 一步到位，且 `Source/Fpc` **早已**在 `tools/qa_check.py` 的 `FPC_DIRS` 豁免名单里（“FPC/Lazarus 平移子工程目录”），FPC-only 单元不污染 Delphi 方言门禁。

这是**编排决策而非技术障碍**，故在此停下。原先并列的另一个未知——7 个 `EZeroDivide`——**已于 2026-10-06 查明根因并修复**（§11.4b，走控件 116/116、`fail=0`），**因此本决策是步骤 3 的唯一剩余阻塞**。
---

## 8. 步骤 1 已完成（2026-10-04）：数据就绪并逐字节校验

| 产出 | 内容 | 校验 |
|---|---|---|
| `Tests/FpcCoreTests/svg/SvgData.pas` | 5 个列表 / 116 条 SVG 的 Pascal 常量 | 逐字节往返 |
| `Tests/FpcCoreTests/svg/svg_manifest.json` | 名称、字符数、sha256 | 供其它工具交叉核对 |
| `tools/f3_svg_extract.py` | 抽取器（`--verify` 开启校验） | 退出码即结论 |

```
VERIFY OK: 116 SVG(s) round-trip byte-identical from the DFM into SvgData.pas.
独立复核（行扫描法，非工具自身的正则）：116 条，长度 0 处不符，全部以 </svg> 结尾
```

### 两个被实测纠正的判断

**① `Size` 不是条目数。** 首版抽取器比较 `Size` 与解析出的条目数，报出「`Size=19` 但解析出 85 条」，看起来像解析失败。实际 `FMX.SVGIconImageList.pas:90` 声明为：

```pascal
property Size: Integer read GetSize write SetSize default 32;   // 像素边长
```

**实测 5 个列表的 `Size` 分别是 19 / 18 /（默认 32）/ 25 / 37 像素** —— 这是控件设计必须知道的约束：**各列表图标尺寸不同，渲染时不能硬编码单一尺寸**。

**② 数据量是 88.6 KB，不是 7.2 KB。** 首版正则只捕获每条字符串续行的**第一块**，把 SVG 截到 64 字符（实为 521）。而当时的 `--verify` 拿截断值与自身比对，**通过了** —— 这是自证式校验的典型失效。

> **教训：校验器必须用与生成器不同的方法。** 后来改用「行扫描法」独立提取再比对长度/结尾，116 条全部吻合。若沿用自比对，这个 12 倍的数据丢失会一路带到 LCL 控件里。

## 9. 步骤 2 已完成（2026-10-04）：`TLclSvgImageList` 写完，**门禁却是假绿灯**

| 产出 | 内容 |
|---|---|
| `Tests/FpcCoreTests/svg/LclSvgImageList.pas` | 控件本体（420 行）：按需光栅化 + (索引,宽,高,主题代) 缓存 |
| `tools/f3_svg_extract.py` | 扩展为同时输出 `SizePx` 与 `Names`，并校验之 |
| `tools/lcl_svg_struct_check.py` | 结构门禁，含 `--self-test`（7 例必须失败） |

### 首版控件有 6 处真实缺陷，而门禁报 OK

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | 类声明未闭合（`= class` 后直接跟自由过程，缺 `public`/`end;`） | 编译失败 |
| 2 | `uses` 缺 `SvgData`、`FPCollections` | 编译失败 |
| 3 | **`LoadSvgLists` 从不装载数据** —— 建空列表，`FSvg` 零赋值 | `Count=0`，**每个图标仍为空** |
| 4 | `Result: TBitmap` 却 `:= TSVGToBitmap.Create`（后者派生自 `TFPCustomImage`） | 编译失败 |
| 5 | stale 分支改的是**局部副本** `Entry.Bitmap`，`FCache` 仍指向已释放对象 | 悬垂指针，`ThemeChanged` 二次 `Remove` 已释放内存 |
| 6 | `Size` 用列表名 if/else 链硬编码 | 改名后静默回落到 32 px 默认值 |

> **缺陷 3 最值得记**：它就是本方案要消灭的「空图标」bug，在修复代码内部被**原样复现了一遍**。控件「能跑」、门禁绿、图标全空。

### 门禁为什么是绿的：注释承诺的检查根本没实现

- `check_balance` 有一段长注释描述「按关键字栈追踪 `begin/end`」——**代码里不存在**，实际只检查 `unit` / `end.` / `begin` 三个字符串在不在。
- `STUB_BODY` 正则**定义了却从未被调用**。

两者都属本项目日志里已记过两次的同一族问题：**「没有模式 = 没有断言」**，以及**「断言覆盖不到组合爆炸」**。

### 修复分两类，第二类才是重点

1. **兑现注释**：真正实现关键字栈平衡检查。
2. **让检查「反空转」** —— 新增 `--self-test`：每个检查都必须**能被证伪**。

> **一个从未失败过的检查，不构成已验证的检查。** 首版门禁只打印过 OK，而它罩住的文件有 6 个编译级缺陷。`--self-test` 给每个检查喂一段**刻意写坏**的片段并要求它报错；若某项检查不再报错，报出来的是「此项检查已空转」，而不是「通过」。

`--self-test` 的 7 个用例首次跑挂，暴露了门禁自身的 3 个缺陷（均已修）：

- **`check_ifdef` 会崩溃** —— `rindex()` 在无 `{$ENDIF}` 时抛 `ValueError`，即**门禁在它要报的那个缺陷上抛异常**，于是什么也没报。
- **例程声明的 `end;` 被当成闭块符** —— Pascal 中声明无 `begin` 即无块，`end;` 是终止符。误算会让栈从此浅一层，其后每个 `end` 都对空栈出栈，把**正确代码**判成 `end with no open block`。
- **`ROUTINE_RE` 把类名当例程名** —— `constructor TFoo.Create;` 报成 `TFoo` 未声明 + `Create` 未实现。

> **门禁误报正确代码，比门禁漏报更危险**：前者训练人忽略它，于是它在真正有 bug 时也一并被忽略。stub 检查最初也这样：它对「`except` 分支释放后置 nil」和「查完列表未命中返回 nil」这类**正当**收尾报错，被收窄为「函数体**只有**那一条赋值」才既不误报又能抓真 stub。

### 门禁的真实覆盖边界（注入缺陷实测，非估计）

| 注入的缺陷 | 门禁 |
|---|---|
| `uses` 去掉 `SvgData` + `FPCollections` | ✅ 抓到 |
| 类丢掉结尾 `end;` | ✅ 抓到 |
| 删掉 `implementation` 段 | ✅ 抓到 |
| **`LoadFrom` 不复制 SVG 数据** | ❌ **抓不到** |
| 例程声明无函数体 | ❌ 抓不到 |

**两个 MISSED 不是遗漏，写下来是为了不再假装覆盖了它们：**

- **语义缺陷抓不到**。区分「正确装载」与「装了个空壳」需要类型系统与数据语义，那是编译器的事。它恰恰是 6 个缺陷里危害最大的那个——**在有 Lazarus 之前，本门禁无法声称能防止它再犯**。它由编译器（nil 数组解引用）与 F3 渲染检查兜底。
- 第二个用例注入的是 `publicX`，**根本不是合法 Pascal**；没有文本级门禁该抓它。

> **由此固化一条边界：结构门禁只管「形状」；凡是「文本正确但行为错误」的失效，都在它的能力之外，必须交给能真正跑代码的东西。**

### 同时修掉的一处「测量结果被重新推导」

原控件用列表名 if/else 链硬编码 19/18/25/37 px，而这些值**抽取器早已实测出来**。这是把一份已有测量复制成第二份，并且**改名即静默退化**。现改为随数据走：`SvgData.TSvgImageList.SizePx`，由 `f3_svg_extract.py` 从 DFM 读出并**纳入往返校验**（`--verify` 会核对 `SizePx` 与 DFM 一致）。同时新增 `Names` 数组并一并校验。

### 步骤 2 的诚实边界

| 项 | 状态 |
|---|---|
| 数据就绪且逐字节校验 | ✅ |
| 控件结构通过门禁，且门禁**自证能失败** | ✅ |
| **能否编译** | ❌ **未验证**（本机无 FPC/Lazarus） |
| **fpvectorial 能否解析全部 116 个图标** | ❌ 未验证 |
| 主题改色是否生效 | ❌ 未验证 |
| 188 处 `ImageIndex` 是否越界 | ❌ 未验证 |

> `Size` 的语义（像素边长而非条目数）现在是**数据事实**而非代码假设，因此 5 个列表的尺寸不会再被任何一条 if 链改写。

## 10. 当前进度与剩余

| 步 | 状态 |
|---|---|
| 1 数据抽取 | ✅ 完成并校验（**双 DFM 覆盖**：`DataFrm` + `NewProjectFrm`，6 列表 / 117 图标，重名即拒） |
| 2 `TLclSvgImageList` 控件 | ✅ **编译 + 运行验证通过**；7 个 `EZeroDivide` 已修复，走控件 **116/116、`fail=0`**（§11.4b），`EXPECTED_MAX_FAILURES` 收紧到 0 |
| 3 DFM 转换规则 | ✅ **完成，并由 §12.7 的探针首次真正加载验证**（6 列表 / 117 图标 / 边长与像素全对） |
| 4 接入 13 个窗体 | ✅ **消费端完成**：15 个 LFM + 68 处绑定全部解析。**生产端 2/3 完成**：`DataFrm` 的 5 个列表 + `NewProjectFrm` 的 1 个列表均已出片段；`Tools/Packman/Main`（无 LCL 对应控件）被**明确拒绝**而非静默放行 |

步骤 3/4 已纯代码完成并经真实 LCL 运行验证（§12）。**当前剩余项**（均不阻塞已交付部分）：

1. **`Tools/Packman/Main`**：需要 `TSVGIconImageCollection` / `TSVGIconVirtualImageList` 的 LCL 对应控件（18 处集合）。
2. **消费端 15 个 LFM 本身尚未被 `lazbuild` 加载**：它们含大量 vendored / 自有控件（`TCompOptionsFrame`、`TSynCppSyn`、`TClassBrowser` 等），受 C 批阻塞；已验证的只是 SVG 列表片段这一层。
3. §7 尚未验证的三项（主题改色、高 DPI 光栅化质量）是质量问题。

> 原第 1 项「抽取器覆盖面」已由 §14.8 关闭：`f3_svg_extract.py` 现读双 DFM，`NewProjectFrm` 的 `SVGIconImageList`（1 条 `Empty`，37 px）已入 `SvgData`，该窗体的片段随之产出。

> 其中第 3 项是本方案当前最诚实的边界：**“SVG 一次解锁 13 个窗体”成立的前提是 SVG 这一个阻塞被清掉；其余阻塞并未随之消失。** §12.6 的实测把“已解锁”与“仍被其它控件阻塞”分开列了，不再给出一个合并后的乐观数字。
---

## 12. 步骤 3 + 步骤 4 完成：转换规则落地，LFM 首次被真正加载（2026-10-06）

本节记录从“能编译的控件”到“**能被 LCL 加载的转换产物**”这一步。**结论先行：转换规则本身很短，短到不需要写；但让这条规则成立的四个前提，每一个都是实测踩出来的，其中两个此前被当作已经解决。**

### 12.1 §11.7 决策落地：产物移入 `Source/Fpc/`

选 (b)，并发现决策的风险比预估低：`tools/qa_check.py` 的 `FPC_DIRS = ("Source/Fpc", "Tests/FpcCoreTests")` **早就把 `Source/Fpc` 列为方言门禁豁免目录**，只是该目录一直不存在。双 profile 门禁实测全绿，FPC-only 单元没有污染 Delphi 构建。

```
Source/Fpc/UI/Controls/LclSvgImageList.pas   控件本体
Source/Fpc/UI/Data/SvgData.pas + manifest     116 条载荷（生成物）
Source/Fpc/UI/Forms/                          转换产物 **50** 个（顶层 37 + Tools/ 下 13）
                                            + _generated.json（溯源清单）
Tests/FpcCoreTests/svg/*.lpr                  探针（保持验证装置身份）
```

> 50 = 34（A 批）+ 15（SVG 消费端）+ 1（SVG 列表片段），与 `f3_lfm_check.py`
> 报的 `.lfm files : 50` 一致。

### 12.2 规则本体：每个列表只剩一个属性

```
object SVGImageListMenuStyle: TSVGIconImageList     对象 X: TLclSvgImageList
  Size = 19                                           ─────────────────────────
  SVGIconItems = < 116 × SVGText …>        ==>         ListName = 'SVGImageListMenuStyle'
  DisabledGrayScale / Scaled / Left / Top
end                                             end
```

**丢掉的每一个属性都有理由，且理由不是“Delphi 没有”**：

| 丢掉 | 为什么 |
|---|---|
| `SVGIconItems`（116 条 / 88.6 KB） | 字节已在 `SvgData.pas`，且 `f3_svg_extract.py --verify` 逐字节守住它。再抄一份等于让同一事实住两家，而那道往返门禁此后只会查其中一家 |
| `Size` / `Height` | 边长由 `AData.SizePx` 给出（19/18/**未声明**/25/37） |
| `Left` / `Top` | LCL 的 `TCustomImageList` 派生自 **`TLCLComponent` 而非 `TControl`**（`lcl/imglist.pp:266`），根本没有这两个属性——留着不是“无害残留”，是加载器会拒绝的属性 |
| `DisabledGrayScale` / `DisabledOpacity` / `Scaled` | vendored 控件专有，LCL 无对应物 |

**`Height` 是这里唯一真正危险的一个**，值得单独记：`SVGImageListClassStyle` 的 DFM 里写的是 `Height = 18`，而它**不是** `Size`。`Size` 在 LCL 上是未知名，丢了就丢了；`Height` 却是 `TCustomImageList` 的合法 published 属性，而**读取器按文件顺序赋值**——它会落在 `ListName` **之后**，把刚按 32 px 载入的列表缩到 18 px。因此规则用的是**白名单**（只保留 `Color`/`BkColor`/`TransparentColor`/`BlendColor`/`Masked`/`AllocBy`），而不是“列出要丢的东西”。

### 12.3 控制端：流式入口必须挂在 `published` 上

转换规则只改文本；真正让 `ListName` 起作用的是控件。**而这一处差点被写成 `public`**：

> `Error reading SVGImageListMenuStyle.ListName: Unknown property: "ListName"`

组件读取器通过 **RTTI** 解析属性名，FPC 只为 `published` 段生成 RTTI。写成 `public`，转换器照样报告成功、LFM 文本照样正确、**每个图标照样是空的**——本项目第三次栽在同一族问题上（§9 记过两次：“没有模式 = 没有断言”）。这次是它的变体：**属性存在，但没有 RTTI**。

此外 `SetListName` 查不到名字时置 `MissingData = True`：因为“查无此列表”和“确实没有图标”从外面看一模一样，而只有后者不是 bug。

### 12.4 三个“沉默的坑”，按踩中顺序

**① `TReader` 在 FPC 3.2.2 下只有二进制驱动。**
`classesh.inc` 里 `TAbstractObjectReader` 只有 `TBinaryObjectReader` 一个具体子类，`TReader.Create` 无条件构造它。指向文本 LFM 时它**不报错，而是挂死**——在 ASCII 上空转等二进制签名。挂死比报错更坏，因为它看起来像控件里的死锁，而不是 API 用错了。正确入口是 Lazarus 自己的 `LResources.ReadComponentFromTextStream`。

**② `ReadComponentFromBinaryStream` 无条件调用 `OnFindComponentClass`。**
`lresources.pp`：`AClass:=nil; OnFindComponentClass(nil,AClassName,AClass);` —— 传 `nil` 不是“用默认值”，是**空方法指针调用**，本机表现为挂死。该事件是 `of object`，需要一个宿主对象，裸函数也不行。

**③ 探针自己把期望值按位置索引。**
`Expected[ComponentIndex]`：一个只含 `SVGImageListProjectStyle` 的片段被拿去和 `SVGImageListMenuStyle` 的 85 图标 / 19 px 比，报出两条与被测代码无关的失败。**LFM 里的顺序不是任何契约的一部分**，依赖位置的期望就不是期望。改为**按名字查**。

### 12.5 最严重的一处：`.lfm` 的溯源表头让它**无法被加载**

转换器原本给每个 `.lfm` 写 `% ...` 溯源表头。四种注释语法全部实测：

```
{ generated header }      -> EParserError: Symbol expected but { found   (1,164)
(* generated header *)    -> EParserError: Symbol expected but ( found   (1,166)
// generated header       -> EParserError: Symbol expected but / found   (1,163)
% generated header        -> EParserError: Symbol expected but found     (1,162)
```

**`TParser` 不跳注释，直接找 `object`。四种都不行**——而“标准注释语法应该能用”正是本项目反复被迫撤回的猜测。

**即：已产出的 34 个 `.lfm` 全部无法被 LCL 读取**，且它们此前只被结构门禁检查过，结构门禁当然看不出问题。改为：**`.lfm` 不带任何注释**，溯源移到旁挂的 `_generated.json`，并让 `f3_lfm_check.py` 断言“每个 `.lfm` 都必须有一条溯源记录”，防止清单腐烂。

### 12.6 步骤 4 的实际完成度（实测，不是估计）

| 项 | 实测 |
|---|---|
| 消费窗体（`Images = dmMain.<list>`）转换 | **15** 个 LFM |
| 消费侧绑定点，全部能在片段里解析到 | **68** 处，0 悬空 |
| 生产端 SVG 片段 | `DataFrm.svg-lists.lfm`（**5** 个列表）+ `NewProjectFrm.svg-lists.lfm`（**1** 个列表） |
| 生产端拒绝 | `Tools/Packman/Main.dfm`（`TSVGIconImageCollection` / `TSVGIconVirtualImageList` 无 LCL 对应物） |

**`NewProjectFrm` 曾是真实缺口，现已关闭**（§14.8）：它内联了一个名为 `SVGIconImageList` 的单条目列表（1 个图标，名 `Empty`，37 px），而 `f3_svg_extract.py` 当初只读 `DataFrm.dfm`。转换器读 `svg_manifest.json` 做交叉校验、名字不在表里就拒绝（而不是放出一个 `Count = 0` 的空列表）——**在缺口补上之前，这个拒绝是正确行为**；缺口本身在抽取器一侧，现已补上。

### 12.7 新增门禁：LFM 首次被真实加载

`Tests/FpcCoreTests/svg/SvgLfmProbe.lpr`（348 行）流式加载**转换器实际产出的每个片段**——按通配符发现 `*.svg-lists.lfm`，不点名文件，否则抽取器新增一个源 DFM 时探针会悄悄漏测。不是自己写的固定样本，否则它与控件同源、只能证明控件能被喂进形状相似的东西。实测：

```
DISCOVERED 2 fragment(s) in Source\Fpc\UI\Forms
STREAMING Source\Fpc\UI\Forms\DataFrm.svg-lists.lfm
  parsed to binary: 422 byte(s)
  streamed root: TSvgImageLists with 5 component(s)

  SVGImageListMenuStyle      Count 85/85  edge 19x19  fail 0  blank 0/85
  SVGImageListProjectStyle   Count  6/ 6  edge 18x18  fail 0  blank 0/ 6
  SVGImageListClassStyle     Count 12/12  edge 32x32  fail 0  blank 0/12
  SVGImageListMessageStyle   Count  7/ 7  edge 25x25  fail 0  blank 0/ 7
  SVGIconImageWelcomeScreen  Count  6/ 6  edge 37x37  fail 0  blank 0/ 6

STREAMING Source\Fpc\UI\Forms\NewProjectFrm.svg-lists.lfm
  parsed to binary:  98 byte(s)
  streamed root: TSvgImageLists with 1 component(s)

  SVGIconImageList           Count  1/ 1  edge 37x37  fail 0  blank 0/ 1

Streamed lists match the data unit: 6 of 6

RESULT: the generated LFM loads and its icons are drawn
```

期望值来自 `SvgData`（第三份独立实现），`SvgData` 与 DFM 的逐字节一致性由 `f3_svg_extract.py --verify` 守住（第四份）。**`RasterProbe` 仍报 7，符合设计**：它绕过控件直喂 fpvectorial，回答的是另一个问题。

### 12.8 门禁的「反空转」验证

新加的检查全部**注入缺陷实测**，而非声称：

| 注入 | 门禁 | 还原 |
|---|---|---|
| 把一个 `ListName` 改错 | ✅ 报「ListName 与组件名不符」 | MD5 一致 |
| 把 `%` 表头加回去 | ✅ 报「首行不是 `object`」 | MD5 一致 |
| 让消费窗体绑定到不存在的列表 | ✅ 报「没有片段声明该列表」 | MD5 一致 |

> 第一版 `ListName` 检查用 `\s*`（在 `re.S` 下**跨行**），于是 `end` 匹配到文件最后一个 `end`，报出 5 条同名失败——每个名字都在和**下一个**组件比。加上 `.lfm` 是 CRLF 而锚点用 `$`（`[ \t]*$` 匹配不到 `\r`），**这些检查一开始一条都没命中**——读起来和全绿完全一样。现在换行先归一化，并在输出里打印 `SVG list fragments: 1 (lists: 5)`，让“命中 0 条”不再长得像“检查通过”。

### 12.9 CI

新增作业 `lcl-svg-runtime`（windows-latest）：先编译 LCL 与 fpvectorial（**两者都不是现成的**，见 §11.1），再从干净检出重新生成数据与 LFM，然后跑 4 个探针，并对两处**设计上的非零读数**断言：转换器因 Packman/Main 拒绝而退出码为 1、`RasterProbe` 仍报 `INCOMPLETE`。

> **诚实的边界**：该作业**只在 Windows 上跑**。探针构建脚本 `build_svg_probe.ps1` 硬编码了 win32 单元目录与 `x86_64-win64`，移植它**没有做**，因此不宣称任何 Linux 徽章。

### 12.10 本轮抓到并修复的缺陷汇总

| # | 缺陷 | 抓到它的 |
|---|---|---|
| 1 | `ListName` 写成 `public`，无 RTTI | 运行时 `Unknown property` |
| 2 | `.lfm` 注释表头使全部 50 个文件无法加载 | 四种注释语法的解析矩阵 |
| 3 | `Height = 18` 会在 `ListName` 之后缩放列表 | 读 LCL 的属性发布顺序 |
| 4 | 集合终止符是 `end>` 而非裸 `>`；需按嵌套计深度 | 解析器 `IndexError` + 28/28 平衡实测 |
| 5 | 片段选择器按**旧**类名筛节点 → 静默跳过所有生产窗体，旧文件留在盘上冒充新产物 | 文件内容与表头对不上 |
| 6 | `NewProjectFrm` 的列表不在 `SvgData` 中 → 会流出空列表 | 转换器对 `svg_manifest.json` 的交叉校验 |
| 7 | `ReadComponentFromBinaryStream` 传 `nil` 即空方法指针调用 | 挂死 |
| 8 | 探针按位置索引期望值 → 报告与被测代码无关的失败 | 一个只含单个列表的片段 |

**第 5 条最值得记**：它是一个**静默的空操作**——代码成功返回、文件保留、`if not svg_nodes` 把它吞掉，而磁盘上的旧文件**带着一张声称规则已生效的表头**。与 §9 记的“缺陷 3”同族：**修复代码内部原样复现了它要消灭的 bug**。

---

## 13. 分支 2：C 批解阻路线图（2026-10-06，实测重算）

上一节结束时"SVG 解锁 13 个窗体"这句话缺一个数：解完之后，**还剩几个真的能编译，剩几个被别的控件挡着**。本节用 `tools/f3_load_routes.py` 从树上重算，替代此前 13 / 15 / 9 三个互相矛盾的手算答案。

### 13.1 关键结论：15 个消费端里，**11 个已无任何阻塞**（F3-3 后重算）

```
  converted .lfm in total     : 52
  of which SVG consumers      : 15
  CLEARED by the SVG work     : 11
  still blocked by other code : 4
```

**「11」不是估计，是交叉验证出来的**——但两个数测的层面不同，差异本身就是证据：`f3_form_survey.py` 从 **DFM 静态侧**（DFM 没动，仍声明 `TVirtualImage`）报「convertible as-is = 43/53」「convertible AND svg-independent = 34/53」，相减 **43 − 34 = 9**；本工具从 **`_generated.json` 产物侧**（含 F3-3 的 `TVirtualImage → TLclVirtualImage` 退役规则）算出 **11**。差 **2** 恰好是 `EnviroFrm` / `LangFrm`：survey 侧仍把它们算作被 `TVirtualImage` 挡着，产物侧该类已退役、阻塞随之消失。两个工具走不同代码路径、不同层面，差值精确等于 F3-3 解锁的窗体数——这正是本项目一贯要求的交叉校验。

### 13.2 下一块最便宜的证据：把这 9 个**加载**出来

`AStyleFormatterOptionsFrm` / `AboutFrm` / `ClangFormatterOptionsFrm` / `FormatterOptionsFrm` / `IconFrm` / `NewTemplateFrm` / `ParamsFrm` / `ToolEditFrm` / `ToolFrm` / `EnviroFrm` / `LangFrm`

这 11 个**无阻塞控件 + 图标列表已是真列表**，即 `f3_lfm_check.py` 之后没有任何东西挡着编译。它们是全计划里**最便宜的剩余证据**——不需要新写任何控件，只需要像 `SvgLfmProbe` 那样把 LFM 喂给真实 LCL 读取器。**这应当优先于任何新控件的编写。**

后两个（`EnviroFrm` / `LangFrm`）是 F3-3 净增的，证据级别与前面 9 个略有不同：§14.7 已验证它们在 `ImageCollections.lfm` 中的 3 个 `TVirtualImage` 节点，但**完整窗体 LFM 从未被完整加载器加载过**。把它们纳入本节清单，正是要把这层证据补齐。

### 13.3 阻断项按「退役一个能解锁几个」排序

| 阻断控件 | 归属 | 解锁窗体 | 目标窗体 |
|---|---|---|---|
| ~~`TVirtualImage`~~ | ~~external~~ | **0**（已由 F3-3 解决：实做 `TLclVirtualImage`，EnviroFrm / LangFrm 已清除；main 仍被其 8 个阻断项挡着） | ~~EnviroFrm, LangFrm, main~~ |
| `TCompOptionsFrame` | own | 2 | CompOptionsFrm, ProjectOptionsFrm（剖析与决策见 §15） |
| `TCompOptionsList` | vendored | 2 | CompOptionsFrm, ProjectOptionsFrm（剖析见 §15：**建议退役**，LCL 原生覆盖） |
| `TSynCppSyn` | vendored | 1 | EditorOptFrm |
| `TClassBrowser` `TCodeCompletion` `TControlBar` `TCppParser` `TCppPreprocessor` `TCppTokenizer` `TdevFileMonitor` `TdevShortcuts` | vendored/external | **各 1** | **全部是 main.dfm** |

**排期结论有两层，第二层比第一层重要：**

- ~~**单点最优是 `TVirtualImage`**（3 个窗体），而且它是 **external** —— LCL 侧有对应物，属于**字段级替换**，不需要写控件。这是投入产出比最高的一刀。~~ **这条已被 Sprint F3-3 实测推翻，见 §14.1。** 被推翻的不是「3 个窗体」这个数，而是「字段级替换」这个**性质**。F3-3 完成后，这把交椅移交给 **`TCompOptionsFrame` + `TCompOptionsList`**（各 2 个窗体；§15 剖析结论：frame 直接移植、list 退役）。
- **`main.dfm` 的 8 个阻断项，每一个都只值 1 个窗体**，而且 8 个里有 5 个是 vendored 自研解析器（`TCppParser` / `TCppPreprocessor` / `TCppTokenizer` / `TClassBrowser` / `TCodeCompletion`）。**把 `main.dfm` 当作一个目标去"清空阻断"，成本是 8 次控件移植；而它本身只有 1 个窗体的收益。** 正确做法是把它**排除出近期排期**，而不是让它绑架整条路线。

### 13.4 生产端缺口（缺的是控件，不是窗体）

```
Tools/Packman/Main.dfm: TSVGIconImageCollection, TSVGIconVirtualImageList  -- 无 LCL 对应物
DataFrm.dfm / NewProjectFrm.dfm: SVG 类已全部转换，但没有窗体级 .lfm，原因在本方案 SVG 范围之外
```

> 第一版的这一节把 `DataFrm.dfm:` 和 `NewProjectFrm.dfm:` **印成了空行**——因为它们唯一声明的 SVG 类正是已退役的 `TSVGIconImageList`，减完就空了。**空行读起来像「没有缺口」，而真实原因是完全不同的阻断项。** 现改为必须带原因打印。

### 13.5 路线图自身的反空转验证

工具的价值全在"会重算"。F3-3 后基线 **52 / 15 / 11 / 4**，做了两次扰动（做完都还原）：

| | 总数 | SVG 消费端 | CLEARED | 仍阻断 | 说明 |
|---|---|---|---|---|---|
| 基线 | 52 | 15 | 11 | 4 | F3-3 后实测 |
| 扰动 A：摘掉 `EnviroFrm.lfm` 条目 | 51 | 14 | 10 | 4 | 模拟一个已清除窗体消失 |
| 还原 A | 52 | 15 | 11 | 4 | `_generated.json` MD5 复原一致（`799542…d51f`） |
| 扰动 B：把 `TCompOptionsFrame`/`TCompOptionsList` 临时加入退役集 | 52 | 15 | **13** | **2** | 前瞻验证 §15 的收益预测 |
| 还原 B | 52 | 15 | 11 | 4 | 工具文件 MD5 复原一致 |

扰动 A 证明数字会随产物集重算；扰动 B 是**前瞻性**的——不改任何代码，只回答「§15 的移植做了，路线图会变成什么样」，答案是 **13 cleared / 2 blocked**（只剩 `EditorOptFrm` 的 `TSynCppSyn` 与 `main.dfm` 的 8 个，后者按上一节结论排除出近期排期）。

### 13.6 一条方法论

> **"还有几个窗体被挡着"是情绪指标，"退役哪一个能解锁几个"才是排期指标。** 前者回答一次就过期，后者每次都能重算。这个区别就是 `f3_batch_plan.py`（批次）与本工具（路线）并存的理由：批次回答"能不能转"，路线回答"先动哪个"。

---

## 14. Sprint F3-3：`TVirtualImage` 实做（本节推翻 §13.3 的第一层结论）

### 14.1 §13.3 的「字段级替换」被推翻

§13.3 把 `TVirtualImage` 记为「external，LCL 有等价物，字段级替换，不需要写控件」。逐个读使用点之后，这个结论在三处全错：

| 使用点 | `ImageCollection` | 集合内条目数 | DFM 的 `ImageIndex` |
|---|---|---|---|
| `EnviroFrm.viThemePreview` | `dmMain.AppearanceThemeCollection` | 9 | `-1` |
| `LangFrm.VirtualImageTheme` | `dmMain.ImageThemeColection` | 9 | `0` |
| `main.ImageEmbarcadero` | `dmMain.EMBTImageCollection` | 2 | `0` |

三处都不是「TImage + TImageList 按索引取图」，而是 **`Vcl.ImageCollection` 的按名取图器**。LCL 的 `TImage` 只有 `Picture`，没有 `ImageCollection` / `ImageName` / `ImageIndex`。

> **顺带订正一个数字。** §13.3 及 `f3_external_matrix.py` 此前记的是「12 / 16 / 4，合计 32 条内联位图」。逐条数过 `DataFrm.dfm` 之后，真实数字是 **9 / 9 / 2，合计 20 条，458,644 字节**。32 这个数是错的，且它一直印在文档里而没人核过——这正是本项目反复吃亏的那一类错误：**一个被引用过很多次的数字，不等于一个被量过的数字。**

### 14.2 真正的前置任务是载荷，不是类

`TVirtualImage` 之所以看起来像「字段级替换」，是因为**载荷藏在类后面**。`DataFrm.dfm` 的 1.74 MB 里有 20 条内联 PNG。丢掉它们再改名，得到的是一个**能编译、能加载、什么都不画**的控件。

所以顺序必须是：**先抽出载荷 → 再写按索引取图的控件 → 最后改名**。跳过第一步就是那个空窗口。

### 14.3 实做结果

| 交付物 | 路径 |
|---|---|
| 提取器（含 `--verify` 字节门禁） | `tools/f3_image_extract.py` |
| 20 个 PNG（与 DFM 逐字节相同） | `Source/Fpc/UI/Data/Images/<集合>/<NN>_<slug>.png` |
| 清单 | `Source/Fpc/UI/Data/img_manifest.json` |
| 索引单元（**不含图像字节**） | `Source/Fpc/UI/Data/ImageCollectionData.pas` |
| 控件 | `Source/Fpc/UI/Controls/LclVirtualImage.pas` |
| 静态门禁 | `tools/f3_imgcoll_check.py` |
| 运行探针 | `Tests/FpcCoreTests/imgcoll/ImgCollProbe.lpr` |

**控件几乎是空的，这是读了 LCL 源码之后的结果，不是偷懒：**

`TCustomImage` **本来就 published 了** `Images` / `ImageIndex` / `ImageWidth` / `Proportional`（`lcl/include/customimage.inc`），而且

```pascal
function TCustomImage.GetHasGraphic: Boolean;
begin
  Result := Assigned(Picture.Graphic) or (Assigned(Images) and (ImageIndex >= 0));
end;
```

也就是说 **`ImageIndex = -1` 在 LCL 里已经是「什么都不画」**，与 VCL 语义一致。而四个调用点（`EnviroFrm.pas:245`、`LangFrm.pas:157`、`LangFrm.pas:235`、`main.pas:7404`）**全部按 `ImageIndex` 驱动**。

于是整个平替 = **把 PNG 装进一个 `TCustomImageList`，赋给继承来的 `Images`，再补两个 LCL 没有的属性（`ImageCollection` / `ImageName`）**。`.pas` 调用点**一行都不用改**。唯一需要设置的默认值是 `Proportional := True`（`TCustomImage.Create` 给的是 `False`，而 `TVirtualImage` 是等比缩放——`LangFrm` 那个控件是 383×103 摆在 671×250 的图上）。

### 14.4 实测抓到的 5 个缺陷（全部先复现、后修复）

| # | 缺陷 | 症状 |
|---|---|---|
| 1 | `TFPColor` 不可见 | `Identifier not found "TFPColor"`——该类型只有 LCL 自己的单元能命名（兄弟探针 `SvgLfmProbe` 也是因为从不声明它才没踩到） |
| 2 | `LastDelimiter` 返回 **1** | 独立小程序实测：`S = D:\Git\Dev-Cpp-Modern\Tests\...`（len 48），`LastDelimiter(S,'\/') = 1`。仓库根路径查找直接跳到盘根并放弃 |
| 3 | `IncludeTrailingPathDelimiter('')` 返回 `PathDelim` 而不是 `''` | 根路径向上走**死循环**。探针 400 秒零输出，看起来像 PNG 解码器死锁——其实根本没走到解码器 |
| 4 | 探针只打印 `E.ClassName` | 20 次失败全是「EConvertError」，没有任何可据以行动的线索 |
| 5 | `TBitmap.Assign(Pic)` 拒绝解码后的 PNG | `EConvertError: Cannot assign a TPicture to a TBitmap.`（`TPicture.LoadFromFile` 其实**成功了**，是我的搬运代码失败了） |

> **#2 / #3 的教训比缺陷本身重要。** 一个「向上找仓库根目录」的辅助函数，配上会缓冲的 stdout，看起来和一个死锁**完全一样**。#3 修好之前，我无法区分「扫描慢」和「卡死」——因为两种情况下探针都不输出任何东西。
>
> **#4 是探针自己的缺陷。** 一条不能据以行动的诊断，等于没有诊断。

### 14.5 探针抓到的两个「不是缺陷的缺陷」

| 现象 | 真相 |
|---|---|
| `viThemePreview.ImageIndex` 停在 `-1` | **代码是对的，期望值是错的。** `EnviroFrm` 写的是 `ImageName = 'Windows Classic'`，而 `AppearanceThemeCollection` 的条目名是 `windows_classic` / `windows_10` / `slate_gray`…… **名字对不上任何一条**。VCL 控件查不到名字就不画图，所以 Delphi 原版的这个预览**本来就是空白**，直到用户点一下 `ListBoxStyle`。平替忠实地复现了这个行为 |
| 载荷必须是文件，不能是生成的单元 | `const BIG: array[0..N] of Byte = ('...')` **根本不编译**：`Incompatible types: got "Constant String" expected "Byte"`。FPC 的类型化常量不接受字符串字面量 |

第一条尤其值得记：第一版期望值写的是 `0`（推理「名字应该能解析」），探针报失败后查下来**错的是期望值**。两个选项里更「说得通」的那个反而是错的。

### 14.6 反空转验证（4 处注入缺陷，逐一被拒）

| 注入 | 谁抓住了 | 退出码 |
|---|---|---|
| 篡改 1 个 PNG 的 1 个字节 | `f3_image_extract.py --verify` **和** `ImgCollProbe` | 都 `1` |
| `ImageCollectionData.pas` 里把宽 671 改成 670 | `f3_image_extract.py --verify`（重建后 `ImgCollProbe` 也报 `got 671x250, manifest says 670x250`） | 都 `1` |
| `ImageCollection` 指向不存在的集合 | 转换器**拒绝转换**，且生成物里不含那个名字 | `1` |
| `ImageHeight = 180`（非 0） | `f3_imgcoll_check.py` | `1` |

全部还原后 MD5 与注入前一致（`ImageCollectionData.pas` = `ce5fa0cc5b2547afa45d2868dedcbd4b`），探针 `exit=0`。

> **注入 #2 第一轮测出了门禁本身的一个假阴性。** 探针报了 `exit=0`——因为我**跑的是旧二进制**：FPC 按 `.ppu` 缓存，不重建就等于测上一轮的代码。
>
> **教训：一个探针只有在刚刚被重建过时才算数。** 这条对 CI 同样成立（CI 每次都重建，所以 CI 里没问题），但任何本地「改完再跑」都必须先 `rm lib/*.ppu`。

门禁自己也被证伪过一次，而且是**门禁报错了**：`f3_imgcoll_check.py` 最初用 `"TVirtualImage" in text` 找残留的 VCL 类，结果命中了探针片段自己的载体类 `TVirtualImageCarrier`——**它的名字里包含它本该顶替的那个类名**。收紧为类声明位置匹配，同时把载体改名为 `TLclVirtualImages`。改检查而不改名字，等于把一个陷阱留给下一个读代码的人。

### 14.7 `EnviroFrm` / `LangFrm` 的状态

两者都已转换，且转换产物经过**真实 LCL 读取器**加载验证（`ImageCollections.lfm` 内 3 个节点全部 stream 成功）。

但**「转换完成」不等于「窗体可用」**：`EnviroFrm.lfm` / `LangFrm.lfm` 本身**仍未被任何完整 LFM 加载器加载过**——它们各自还有 90 多个其它控件类需要注册。片段验证证明的是**这三个节点转对了**，不是**这两个窗体能打开**。

### 14.8 抽取器覆盖面 + 门禁自身的两处欠账（2026-10-06）

F3-3 收尾阶段的三件事，全部由实测驱动。

**1. 抽取器覆盖面关闭**（§10 第 1 项、§12.6 的缺口）：`f3_svg_extract.py` 从只读 `DataFrm.dfm` 扩到也读 `NewProjectFrm.dfm`。两个输入带来两个新要求：**重名即拒**（两个 DFM 声明同名列表是数据冲突，不是合并），以及 `--verify` 重读两个文件做往返。实测：`lists: 6   items: 117`，`VERIFY OK: 117 SVG(s) round-trip byte-identical from 2 DFM(s)`。

**2. `f3_lfm_check.py` 的三处欠账**（修复前实测报 6 处误报：5 个文件的树比较 + 1 处孤儿）：

| 欠账 | 修复 |
|---|---|
| 孤儿检查按**文件名后缀**豁免 fragment（只认 `.svg-lists.lfm`），`ImageCollections.lfm` 被误报「orphan LFM with no source DFM」 | 按 `_generated.json` 的 **rule** 豁免：凡 rule 以 `-fragment` 结尾的都是从 DFM 撕下的子树，不是窗体——未来的 fragment 类型不会被误报 |
| 树比较不认 `CLASS_RENAME`：DFM 侧的 `TSVGIconImageList` / `TVirtualImage` 与 LFM 侧重写后的类型被当成 drift，5 个窗体文件误报 | DFM 侧比较前过一遍转换器自己的 `CLASS_RENAME` 表（importlib 按路径加载，**不抄第二份**——两份表迟早漂移） |
| BANNED 集的注释声称「与 `f3_dfm_to_lfm.DROP_PROPS` 互相断言」，但断言只存在于注释里 | 断言真正落实：`DROP_PROPS - BANNED` 非空即报失败（实测 14 = 14，通过） |

**3. 探针与 CI 的硬编码计数**：`SvgDataProbe`（`SvgListCount <> 5`）与 `SvgLfmProbe`（`Expected: array[0..4]`、单文件硬编码）在 6 列表下会失败。修法是**消除硬编码**而不是改数字：`SvgDataProbe` 的汇总行改为动态累加；`SvgLfmProbe` 重构为通配符发现所有 fragment、逐个流式加载、断言**联合**组件数 = `SvgListCount`（单个 fragment 本就只含一个窗体的列表，联合才是不变量）。`RasterProbe` 本就无硬编码，实测 `rendered ok : 110`（新的 `Empty` 图标有墨水），CI 的步骤名与正则同步。

实测收尾（除转换器按设计 `exit=1` 外，全部 `exit=0`）：

```
f3_svg_extract  --verify : VERIFY OK: 117 SVG(s) round-trip byte-identical from 2 DFM(s)
f3_image_extract --verify: OK: 20 images / 3 collections byte-identical to DataFrm.dfm
f3_imgcoll_check          : OK: 3 TVirtualImage node(s) converted, payload byte-identical
f3_lfm_check              : PASS（55 .lfm / 52 compared / 2 fragments = 6 lists / 69 绑定 / 55 溯源记录）
f3_dfm_to_lfm --only svg  : exit 1（Packman/Main 拒绝，设计如此，CI 显式断言）
SvgDataProbe              : RESULT: data unit delivers 6 lists / 117 payloads
SvgLfmProbe               : DISCOVERED 2 fragment(s) … Streamed lists match the data unit: 6 of 6
SvgListProbe              : renderer failures over all lists = 0
RasterProbe               : rendered ok : 110 … RESULT: INCOMPLETE（绕过控件直喂 fpvectorial，设计如此）
ImgCollProbe              : RESULT: the converted LFM streams and every PNG decodes with content
```

探针全部在清掉 `.ppu` 缓存后重建再跑——§14.6 的教训对这里同样适用：`SvgData.pas` 从 5 列表变成 6 列表，不重建就跑等于测上一轮的代码。

---

## 15. 头号阻断项剖析：`TCompOptionsFrame` + `TCompOptionsList`（2026-10-06）

F3-3 之后路线图的头号共享阻断项：各解锁 2 个窗体（`CompOptionsFrm` / `ProjectOptionsFrm`），是 `main.dfm` 之外唯一「一动多」的目标。本节给出实测剖析与 **Frame-port 决策**。

### 15.1 两个控件是什么

**`TCompOptionsList`**（`Source/VCL/CompOptionsList/CompOptionsList.pas`，103 行，vendored）：`class(TValueListEditor)` 加一个 `TInplaceEditListAccess = class(Grids.TInplaceEditList)` 的私有类 hack，依赖 VCL 私有成员 `EditList` / `StyleServices` / `ItemProps[].HasPickList`。它的全部「增值」只有两处：`DrawCell` 里的 `StyleServices.DrawElement` 调用——**是注释掉的死代码**；`MouseDown`——只调 `TInplaceEditListAccess(EditList).DropDown` 弹下拉。

**`TCompOptionsFrame`**（`Source/CompOptionsFrame.pas`，139 行，own）：`class(TFrame)`，`tabs: TTabControl` + `vle: TCompOptionsList`，三个方法：

- `FillOptions`：从 `devCompilerSets[fCurrentIndex].Options` 收集 section 名（经 `Lang[...]` 本地化）去重加入 `tabs.Tabs`；
- `tabsChange`：按当前 tab 过滤选项，`vle.InsertRow(...)` 逐行插入（有 `Choices` 用选项名，否则用 `BoolValYesNo`），`Strings.Objects[idx] := Pointer(I)` 记下标，`ItemProps[idx].EditStyle := esPickList`、`ReadOnly := true`、填 `PickList`；
- `vleSetEditText`：把 Yes/No 或选项名映射回 `option^.Value`，调 `CompilerSet.SetOption` 写回编译集。

### 15.2 关键实测：`TCompOptionsList` 在 LCL 上是冗余的

LCL `valedit.pas` 对 `esPickList` 行**原生**提供组合编辑器（实测行号）：

```
valedit.pas:17    TEditStyle = (esSimple, esEllipsis, esPickList);
valedit.pas:309   property DropDownRows: Integer ... default 8;
valedit.pas:1267  esPickList: begin
valedit.pas:1268    result := EditorByStyle(cbsPickList);   // 原生下拉编辑器
                    (result as TCustomComboBox).Items.Assign(ItemProp.PickList);
                    DropDownCount := DropDownRows;
```

即：凡 `EditStyle := esPickList` 的行，LCL 的 `TValueListEditor` **自己**给下拉按钮、`PickList`、`DropDownRows`——vendored 控件用私有 hack 手搓的那套，在 LCL 里一行都不用写。而 `TCompOptionsFrame` 的全部代码（`InsertRow` / `Strings` / `ItemProps` / `PickList` / `ReadOnly` / `ColWidths` / `OnSetEditText` / `TTabControl.Tabs` / `OnChange`）**没有一处**用到 vendored 控件的独有行为——`DrawCell` 与 `MouseDown` 的覆写在这个 frame 里根本不会被触发。

**结论：`TCompOptionsList` 退役，`vle` 直接用 LCL 原生 `TValueListEditor`。**

### 15.3 决策：Frame-port（直接移植 frame），不是 field-simplification

两个候选：

- **Frame-port**：移植 `TCompOptionsFrame` 本身，`vle` 字段类型换成 `TValueListEditor`，退役 vendored 控件；
- **field-simplification**：拆掉 frame 容器，把 `TTabControl` + `TValueListEditor` 直接铺进两个窗体。

选 Frame-port，理由全部可测：

1. frame 的三个方法逻辑真实且**在两个窗体间共享同一行为**（同一 `devCompilerSets` 的选项编辑）；拆成两份会复制约 80 行逻辑，迟早漂移——这正是本项目「一份规则一处」纪律的反面。
2. frame 的依赖全部是在仓内已移植单元：`devCFG`（`BoolValYesNo` :29、`TdevCompilerSet` :46、`TdevCompilerSets` :146、`SetOption` :109）、`ProjectTypes`（`TCompilerOption` / `PCompilerOption`）、`utils`、`MultiLangSupport`、`project`。**没有 VCL 私有单元依赖**——vendored 的 `CompOptionsList` 反而是唯一的 VCL 私有依赖，退役它即斩断。
3. LCL 属性面逐项验证过：`InsertRow`（valedit.pas:188）、`ItemProps`（:203）、`TItemProp.ReadOnly`（:51）、`DropDownRows`（:309）、`TTabControl.Tabs`（comctrls.pp:888）、`OnChange`（:877）、`OnSetEditText`（valedit.pas:296）、`goAlwaysShowEditor`（grids.pas:101）、`doKeyColFixed`（valedit.pas:106）、`BorderStyle`（grids.pas:1225）、`DefaultRowHeight` / `ColWidths` / `FixedCols`（grids.pas:1238 / 1236 / 1254）。

### 15.4 移植改动清单（文件级，实测）

| 文件 | 改动 |
|---|---|
| `Source/CompOptionsFrame.pas` | `vle: TCompOptionsList`（:31）→ `vle: TValueListEditor`；uses 去 `CompOptionsList`（`ValEdit` 已在） |
| `Source/CompOptionsFrm.pas` | uses 去冗余的 `CompOptionsList`（:27——全文件无 `TCompOptionsList` 直接类型引用，实测） |
| `Source/CompOptionsFrame.dfm` | `object vle: TCompOptionsList` → `object vle: TValueListEditor`；属性全部 LCL 原生，**一行不用删**（`DropDownRows=40`、`BorderStyle=bsNone`、`DefaultRowHeight=22`、`DisplayOptions=[doKeyColFixed]`、`FixedCols=1`、`Options=[goEditing,goAlwaysShowEditor]`、`ScrollBars=ssNone`、`ColWidths=(199,364)`） |
| 两个窗体 LFM | 重跑转换器即可：`CompOptionsFrm.lfm:158` 的 `inherited vle: TCompOptionsList` 自动变为 `TValueListEditor`（转换器 OBJ_RE 原生认 `object/inherited/inline`，f3_dfm_to_lfm.py:143；两个窗体的 `inline CompOptionsFrame1: TCompOptionsFrame` 节点不变） |

frame 的 Pascal 逻辑代码**零改动**——它用的每个符号都是 LCL 原生 API。

### 15.5 收益（前瞻扰动实测，非估计）

§13.5 扰动 B 已验证：把这一对加入退役集后路线重算为 **52 / 15 / 13 / 2**——`CompOptionsFrm` 与 `ProjectOptionsFrm` 解锁，剩余阻断只剩 `EditorOptFrm`（`TSynCppSyn`）与 `main.dfm`（8 个，按 §13.3 结论排除出近期排期）。

### 15.6 与 §14 的关系

§14 推翻了「`TVirtualImage` 是字段级替换」的性质判断；本节是同一性质判断的**正例**：`TCompOptionsList` 是真冗余（死代码 + LCL 原生覆盖），`TCompOptionsFrame` 是真逻辑（需要移植）。一刀切地「全部字段级替换」或「全部移植」都会误判——逐控件实测才是排期依据。
---

## 16. Sprint F3-4/F3-5：13 个窗体**全部真的能加载**（2026-10-06）

§15 的结论是“把 `TCompOptionsFrame` 移植过来，`CompOptionsFrm` 与 `ProjectOptionsFrm` 就解锁”。本节记录这项移植**做完之后**发生的事——**结论先行：13 个 CLEARED 窗体现在全部通过真实 LCL 读取器加载，0 失败**；而通往这个结论的路��，先要修掉**三个此前被当成已经解决的转换器缺陷**，否则“转换成功”这个词一直是不成立的。

| 探针 | 结果 |
|---|---|
| `PropRttiProbe` | `refused by the reader : 0`——14 个转换文件里 **3457 条属性赋值**逐条过了读取器 |
| `FormLfmProbe` | `Streamed forms: 13 of 13`，`Ancestor fallbacks : 0` |
| `f3_lfm_check` | PASS（55 lfm / 52 比对 / 69 绑定 / 55 溯源） |
| 反空转注入 | 7 处注入，**6 处被拒**（第 7 处是文档化的空串语义，不是漏网） |

### 16.1 转换器的三个缺陷（都是**先复现、后修复**）

**1. 根对象的 `end` 位置错了 → 所有子控件被静默丢弃。**
旧转换器把每个对象平铺在根的 `end` 之后（“读取器保留平序”）。实测（`MiniLfmTest`）：
一次 `ReadComponentFromBinaryStream` **只读第一个顶层对象**，后面的兄弟节点全部消失——窗体流回来 `ComponentCount = 0`，13 个窗体同时挂掉。**旧假设被自己的断言 4 推翻**，现在按 DFM 缩进重建嵌套树，并加了一道“只有一个根”的硬拒。

**2. 属性值不是按整体读的 → 十六进制块和值顺序错位。**
旧读取器把“不能识别成属性的行”塞进一个 `binary` 桶，**追加到该节点属性列表末尾**。而 `Picture.Data` 在 DFM 里写在 `Proportional` 和 `Stretch` **之间**，于是生成的 LFM 出现

```
Picture.Data = {
}
Proportional = True
ShowHint = False
Stretch = True
0954506E67496D61676589504E47...
```

大括号在下一行就闭合了，一兆十六进制落在了「该出现属性名」的位置。**实测对真实 LCL 读取器就是** `Wrong token type: Symbol expected but Float found`，`AboutFrm` / `IconFrm` / `ToolFrm` 同时中招。属性**顺序不是排版问题**：读取器按文件顺序赋值，且要分词，只有“每个值的 token 连在一起且顺序正确”才成立。

**3. 读取器会跳过它读不懂的行。**
旧读取器**静默跳过**不认识的行——这正是“某个属性可以从窗体里消失、而转换还报成功”的成因。现在解析器记录**已消费的行**，剩一行就报错并给出行号。

### 16.2 探针自身的三个缺陷（与产品缺陷无关，但同样致命）

| 缺陷 | 症状 | 根因 |
|---|---|---|
| frame 资源注册成了**文本** | 两个 frame 窗体 `Invalid Filer Signature` | `TLRSObjectReader.BeginRootComponent`（`lresources.pp:3990-3998`）读**4 个原始字节**比对 `'TPF0'`，尽管该类有分词 API。实测编译产物：`lhelp.exe` 里 `'TPF0'` 出现 2 次——**Lazarus 嵌入的就是二进制 LFM** |
| frame 桩的两个处理函数声明在 `public` | `tabs.OnChange: Invalid value for property` | frame 的 LFM 经 **LCL 自己的读取器**加载，没有方法钩子；`RTTIGetMethod` 只看得见 **published** 方法 |
| `PropRttiProbe` 自己的提问器**对所有属性都答“拒绝”** | 49 条候选全部 `Read Error`，看起来像结论 | `LRSObjectTextToBinary` 把输出流留在**末尾**，读取器从 EOF 开始 |

第三条最值得记：**一个只会说“不”的提问器，和一个正确的结果长得一模一样。** 因此 `PropRttiProbe` 每次运行都先**自测**：4 个 LCL 确有的属性必须被接受、2 个 LCL 没有的必须被拒绝、3 个点号路径形式必须按子属性接受，**8 个自测问题双向都能回答之后**才允许输出结论。

> **本轮第 4 次踩到“旧二进制”**（§14.6 已记过一次）：注入实验后没重建就重跑，探针报的是上一轮代码的结论。注入矩阵因此要求**每次还原后重建**，且还原后校验 MD5。

### 16.3 17 条被读取器拒绝的属性：用 LCL 自己的机制，而不是删掉它们

把每个属性都交给读取器之后，17 条被拒。其中最要紧的一条是 **`DesignSize`**——第一版审计先问 RTTI，把它列为“未知”，而它其实是 LCL **自带的** `TControl.designsize` 跳过项（登记表里就有）。**问 RTTI 会给出错误答案**；问读取器才对。

处置方式的选择很关键。`f3_dfm_to_lfm.py` 的 `DROP_PROPS` 里已经写着理由：

> 提前删掉一个真实属性比留着一个未知属性更糟，因为 LCL 加载器会报告它**不喜欢什么**，而被删掉的属性之所以没有报告，正是因为**没人再检查它**。

`DROP_PROPS` 是给 Delphi 记账属性用的（`PixelsPerInch`、`Explicit*`、`OldCreateOrder`、`Ctl3D`）——那些值离开 Delphi 设计器就没有意义。这 17 条不同：每一条都是真实控件的真实属性，删掉等于**把作者的意图从转换产物里抹掉，而 .dfm 还留着**。

LCL 有专门的机制，而且 **LCL 自己在用**：`RegisterPropertyToSkip`（`lresources.pp:607`），按**类**+属性名登记，`CreateLRSReader` 把它挂上（`lresources.pp:3196`），匹配走 `AClass.InheritsFrom`（`lresources.pp:680-698`）。Lazarus 对同样的 VCL 遗留就是这么处理的：`synedit.pp:10752` 登记 `TSynGutter.ShowCodeFolding`，`customlistview.inc:794-796` 登记 `TListItem.OverlayIndex`。

**按类登记是这里的关键差别**：全树 `BevelOuter` 出现 **82 次 / 31 个窗体**，其中 97% 在 `TPanel` / `TImage` 上——**LCL 这两个控件是有 `BevelOuter` 的**（`extctrls.pp:1161`）。一个按名字删的表（本仓库 `DROP_PROPS` 就是）会连带删掉 **95 个本来能工作的属性**。

| 类别 | 属性（类.属性，站点数） | 为什么安全 |
|---|---|---|
| 重复键 | `TBitBtn/TSpeedButton.ImageName`（50） | 每处都同时带 `ImageIndex`，而全仓库**零处**代码读 `ImageName` |
| public 非 published | `TBitBtn.DoubleBuffered`（1） | LCL 在 `controls.pp:2322` 起的 **public** 段声明它，LFM 只能赋 published |
| 换基类丢失 | `TBitBtn.WordWrap`（1） | LCL 在 `TButton` 上 published（`stdctrls.pp:945`），`TBitBtn` 不继承它 |
| VCL 特有机制 | `TBitBtn/TListBox.StyleElements`（2） | vcl-styles-utils 概念，LCL 无 styles 服务 |
| LCL 无对应绘制 | `TListView.BevelInner/BevelOuter`（2） | **按类登记**；`TPanel`/`TImage` 不受影响 |
| 属性改名 | `TListItems.ItemData`（1） | LCL 用 `Items.Data`（`listitems.inc:547`）；且 `IconFrm.FormCreate` 会 `Items.Clear` 后从磁盘重建 |
| **功能缺失** | `TListView.OnInfoTip`（1） | `IconFrm.pas:140` 有真实处理器；**图标浏览器会失去提示气泡**，LCL 无此事件 |
| 折叠机制不同 | `TSynEdit.UseCodeFolding` / `CodeFolding`（各 4） | LCL 由 highlighter 能力位 + `TSynGutterCodeFolding` 驱动；且 `devCFG.pas:2551-2559` 从**代码**设置 |
| **视觉差异** | `TSynGutter.Font`（20） | LCL gutter 无 Font，改用 `TSynEdit.Font`；驱动它的 `EditorOptFrm.pas:249-251` 属 SynEdit 移植工作 |

`Gutter.Font.*` **只登记一条**（`TSynGutter.Font`）而不是五条：读取器逐段走点号路径，**在第一个缺失段就放弃整条路径**（`reader.inc:1297-1302` 然后 `:1270-1274`），而那一刻实例正是 gutter 本身。

### 16.4 登记表本身也要被审计（而且第一版审计是错的）

`PropertiesToSkip` 是**钝器**：登记一次就对该类**及其全部子类**生效，而且是**静默**抑制。第一版审计按“登记的属性必须不在类的 RTTI 里”检查全局表，**当场报出一条 FAIL**：

```
FAIL TForm.Scaled is registered to be skipped but the class DOES have it
```

——**LCL 自己登记的**，而且 TForm 确实有 `Scaled`。那类登记是给对象检查器用的，不是为了抑制赋值。所以“登记表被审计”只能指**本项目那张表**，两张表必须可区分：`VclPropertySkips` 因此把条目暴露成**数据**（`ENTRIES` + 访问器），探针只审自己的 13 条，并检查每条都带**说明**。于是：

* 少登记一条 → 探针报 `REFUSED ... BevelOuter`（exit 1）
* 多登记一条**类确实有**的属性 → 探针报 over-broad（exit 2）

两条都是**注入实测**，不是设想。

### 16.5 剩余的诚实边界

* **`f3_removed_controls.py` 此前并没有断言 `CompOptionsList`**——`f3_load_routes.py` 的注释却写着“`f3_removed_controls.py` asserts it stays that way”。补上之后又发现它**第一版是空的**：它只搜类型名 `TCompOptionsList`，而 uses 子句里出现的是**单元名** `CompOptionsList`。注入回一条 `uses` 声明，**门禁照样绿**。现已改为登记单元名。
* **`OnInfoTip` 是功能缺失**，不是排版差异：图标浏览器的气泡提示需要单独移植。
* **`TSynGutter.Font` 是视觉差异**：LCL gutter 跟随编辑器字体。
* 门禁全部通过**只说明这 13 个窗体的转换产物可加载**，不说明窗体**可用**：处理器是否与移植后的单元对得上，由 FPC 编译器在单元编译时检查。
