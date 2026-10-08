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
| 4 接入 14 个窗体 | ✅ **消费端完成**：15 个 LFM + 68 处绑定全部解析。**生产端 2/3 完成**（消费端已解锁 14 个，见 §17）：`DataFrm` 的 5 个列表 + `NewProjectFrm` 的 1 个列表均已出片段；`Tools/Packman/Main`（无 LCL 对应控件）被**明确拒绝**而非静默放行 |

步骤 3/4 已纯代码完成并经真实 LCL 运行验证（§12）。**当前剩余项**（均不阻塞已交付部分）：

1. **`Tools/Packman/Main`**：需要 `TSVGIconImageCollection` / `TSVGIconVirtualImageList` 的 LCL 对应控件（18 处集合）。
2. ~~**消费端 15 个 LFM 本身尚未被 `lazbuild` 加载**~~ **已关闭（§16/§17）**：SVG 消费端中**无阻塞控件**的 14 个窗体现在全部通过真实 LCL 读取器加载（`FormLfmProbe` 14/14）。仍被挡着的是 `main.dfm`（8 个 vendored/external 阻断项，按 §13.3 结论**排除出近期排期**）与 `DataFrm.dfm`（`TSynRCSyn` + `TImageCollection`，§17.2）。**已加载 ≠ 已可用**：窗体的 Pascal 单元能否对 LCL 编译仍待 FPC 验证。
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

## 17. Sprint F3-6：退役 vendored `TSynCppSyn`，`EditorOptFrm` 解锁（2026-10-07）

§16 结束时，SVG 消费端只剩两个窗体被挡着：`EditorOptFrm`（`TSynCppSyn`）与
`main.dfm`（8 个阻断项）。本节记录退役前者之后发生的事。**结论先行：14 个
CLEARED 窗体现在全部通过真实 LCL 读取器加载**；而通往这个结论的路上，先要修掉
**审计工具自身三个正在输出健康数字的缺陷**，否则"0 处被拒"这个结论从一开始就不成立。

| 探针 / 门禁 | 结果 |
|---|---|
| `f3_load_routes.py` | CLEARED **13 → 14**，仍阻断 **2 → 1**（只剩 `main.dfm`） |
| `FormLfmProbe` | **`Streamed forms: 14 of 14`**，`Ancestor fallbacks : 0` |
| `PropRttiProbe` | **`refused by the reader : 0`**（15 个文件 / 4318 条归属属性） |
| `f3_form_ratchet.py` | 可转换数 **44 → 45**，基线已显式写入 |
| `f3_probe_inject.py`（新增） | 4 处注入**全部被拒**，4 个文件按 MD5 逐一还原 |

### 17.1 一个"这个类不存在"的假象，以及它为什么出现

第一件事是复核 §13.3 声称的"REPLACE 级：LCL 自带 `TSynCPPSyn`"。按类名去找，
在 Lazarus 里**什么都找不到**：

```
components/synedit\*.pas    ->  没有
components\synedit\**\*.pas ->  没有
```

**原因不是 LCL 没有这个类，而是它的源文件不叫 `.pas`。** Lazarus 把 SynEdit
的高亮器写成 **`.pp`**：

```
components\synedit\synhighlightercpp.pp                            <- 源文件在这里
components\synedit\units\x86_64-win64\win32\synhighlightercpp.ppu  <- 已编译
```

类名两棵树完全一致：vendored 侧 `TSynCppSyn = class(TSynCustomHighlighter)`
（`Source/VCL/SynEdit/Source/SynHighlighterCpp.pas`，211 行），LCL 侧同名同基类。
基类 `TSynCustomHighlighter` 在**两棵树里都派生自 `TComponent`**——这正是读取器
能够 own 并流式化一个非可视组件的前提。

> **为什么这条值得单独写**：本项目此前已经吃过两次"按名字找类，找不到就断言不存在"
> 的亏（`TVirtualImage`、`TToolButton`）。这一次它不是记错，而是**检索式本身错了**。
> 因此 `f3_form_survey.py` 里的新集合**不接受名字匹配**，注释里写明了两侧各自的
> 证据位置（源码 `.pp` + 已编译 `.ppu`）。

### 17.2 顺带更正本文档此前的一处断言：`TSynRCSyn` 在 LCL 里**不存在**

§12/§13 写过"LCL SynEdit 自带 `TSynCPPSyn` / `TSynRCSyn` / `TSynPASyn`"。
逐个核实后：

| 类 | LCL 4.4 | 结论 |
|---|---|---|
| `TSynCppSyn` | 有（`synhighlightercpp.pp`） | 可退役 |
| `TSynPASyn` | 有（`synhighlighterpas.pp`） | — |
| `TSynRCSyn` | **无**。`components/synedit` 下既无源码也无已编译单元 | **不得退役** |

**若照原文整条采信**，`DataFrm.dfm`（唯一使用 `TSynRCSyn` 的窗体）会被一并
解锁，然后在读取器上死于 `Class TSynRCSyn not found`——即 §13.4 所说的
"生产端缺口"。因此 `TSynRCSyn` 被**刻意留在阻断集合里**，`DataFrm` 至今仍被
`TSynRCSyn` + `TImageCollection` + SVG 列表三者共同挡着。

**这条也说明为什么"一个清单条目"必须逐个核实**：`TSynRCSyn` 与 `TSynCppSyn`
名字前缀相同、用法相同（都是 `object x: TSyn…Syn`）、都来自 vendored SynEdit。
凭"同一批"的印象一并处理，就会把一个不存在的类登记成可用的。

### 17.3 两份清单不是同一类东西（`WIDGETSET` vs `LCL_SUPPLIED`）

新增集合**没有**并入既有的 `WIDGETSET`，因为两者回答的是不同问题：

| 集合 | 回答的问题 | 判据 |
|---|---|---|
| `WIDGETSET` | 这个控件**能被放进窗体**吗 | 它是不是可摆放的 TControl |
| `LCL_SUPPLIED` | LCL 有没有**同名**类、读取器能流式化吗 | 类名解析 + 基类是 TComponent |

高亮器**不能被摆放**：它派生自 `TComponent`，没有 `Left`/`Top`，作为子控件毫无意义。
把它塞进 `WIDGETSET` 等于为了让计数好看而对类本身做出**错误的断言**。

`LCL_SUPPLIED` 当前只有一个成员 `TSynCppSyn`，并附一条**明确不声称**的内容：

> 两棵树的 token 枚举**并不相同**。vendored 的 `TtkTokenKind` 在 LCL 的 11 个值之外
> 还有 `tkChar` / `tkFloat` / `tkHex` / `tkOctal`。因此**照原样针对 Delphi 枚举写的
> 高亮器代码不会原样重编译通过**。这是 **Pascal 单元**（`EditorOptFrm.pas`）的问题，
> 属于 F2 的 SynEdit 移植，不属于窗体问题。此条目只声称"类名能解析、能流式化"，
> 而这正是解锁窗体所需的那一条。

### 17.4 顺带补上的三个控件类

`EditorOptFrm` 是第一个带 `TSynStringGrid` / `TColorBox` / `TTrackBar` 的 CLEARED
窗体，此前从未向探针的类注册表提过要求。三个都是 LCL 原生类，**按声明核实**
而非按名字推断：

| 类 | 位置 | 基类 | 出现次数 |
|---|---|---|---|
| `TTrackBar` | `lcl/comctrls.pp` | `TCustomTrackBar` | 2 |
| `TColorBox` | `lcl/colorbox.pas` | `TCustomColorBox` | 5 |
| `TStringGrid` | `lcl/grids.pp` | `TCustomStringGrid` | 1 |

探针注册的是**真实类**而非桩——`EditorOptFrm` 在这三者上都赋了真实属性。

### 17.5 六条新的属性跳过登记，以及它们各自的代价

沿用 §16.3 的纪律：**用 LCL 自己的 `RegisterPropertyToSkip` 按类登记，而不是在
转换器里删掉**。6 条新增（登记表共 19 条），逐条附实测理由：

| 类.属性 | 站点 | 代价 |
|---|---|---|
| `TSynCppSyn.Options` | 3 | **能力缺失**。`Options` 是第三方补丁（vendored 源码里明写 `// <-- Codehunter patch`），`TSynEditHighlighterOptions` 这个类型在 vendored 树里再无第二处、在 LCL 里根本没有。三个值全是关闭态（`AutoDetectEnabled=False` / `AutoDetectLineLimit=0` / `Visible=False`），故"没有开着却被忽略的功能"。**一条登记覆盖三条**，因为读取器在首个缺失段放弃整条路径 |
| `TSynEdit.AddedKeystrokes` / `RemovedKeystrokes` | 4 个集合块 | **功能缺失，且代价可量化**。这是 VCL 的按键命令绑定表：把 F1 改绑到上下文帮助（5 处）、再加 Ctrl+F1（16496）。两棵树**任何一个 LCL 单元都没有这两个属性**，所以没有可改名的对应物——不是换个名字，是没有。**边界已实测**：这两个名字在全仓只出现在 **2 个 DFM**（`EditorOptFrm`、`CPUFrm`）、**0 行 Pascal**，因此无代码读写，丢掉的是设计期默认值 |
| `TSynGutter.BorderStyle` | 3 | **无代价**。LCL 的 `TSynGutter` 没有 `BorderStyle`，而三处全是 `gbsNone`（不画边框）——与 LCL 的画法一致。跳过是因为**名字不存在**，不是因为意图有别 |
| `TSynGutter.GradientEndColor` | 1 | **视觉差异**。LCL gutter 平涂，无渐变；VCL 原本向该颜色混合 |
| `TSynEdit.ScrollHintFormat` | 1 | VCL 专属滚动条提示方向，LCL 无对应物 |

> **只登记集合本身，不登记内部的 `Command` / `ShortCut`**：`AddedKeystrokes` 的
> 跳过会让读取器 `SkipValue` 并放弃整条路径，内部行根本不会成为属性。**这是
> 实测出来的，不是推断的**——先按这样只登记集合，14/14 通过；再把 `Command` /
> `ShortCut` 也登记上去，就成了 §16.4 所说的"过宽登记"，而探针的登记表审计正是
> 为抓这一类而存在。

### 17.6 本批最重要的产出：**审计工具自己在输出健康数字**

三个缺陷，形态与本项目此前记录的三次同类（"断言覆盖不到未走的路径"），但**这次是被
一个"数"引出来的，不是被一个失败引出来的**。

**① 集合守卫比较了 2 个字符和 4 个字符的字面量。**

```pascal
// 原始（永远为假）
if (Length(Trimmed) > 2) and (Copy(Trimmed, Length(Trimmed) - 1, 2) = ' = <') then
// 正确（字面量 ' = <' 共 4 个字符）
if (Length(Trimmed) > 4) and (Copy(Trimmed, Length(Trimmed) - 3, 4) = ' = <') then
```

`Copy` 取 2 字符，与 4 字符字面量**恒不相等**，于是 `CollectionBlocks` **在结构上
无法自增**。它在真实含有 **5 个**集合块的语料上打印 `0`。

**② `ValueLastLine` 不认识 `<`，于是"被拒"变成了"通过"。**

守卫失效后，集合开括号落到属性分支，而 `ValueLastLine` 只建模 `(`、`{`、`+`。
于是读取器收到的是：

```
object Probe1: TSynEdit
  RemovedKeystrokes = <
end
```

**一个未闭合的集合不会报拒绝，它报成功**——因为这个属性根本没有以属性的形式
到达读取器。实测后果：`TSynEdit.RemovedKeystrokes` 被打印为 `reader accepts`，
**而这个属性在 LCL 的任何单元里都没有声明**（`components/synedit/*.p*` 全树 0 命中）。

> **一个把自己没送出去的东西报成"没问题"的审计，比一个什么都不报的审计更糟。**
> 而发现它的不是任何一个计数，是一句追问：**"LCL 明显没有这个属性，为什么它
> 回来了 accepted？"**

**③ 内部 `item` 行被归属到了外层对象。**

只跳过开括号一行，`item` 行的 `Command` / `ShortCut` 就按当前深度落到了外层
`TSynEdit` 头上，于是探针报出两条**并不存在**的拒绝（各 7 处站点）——并且会把人
引向两条**给 `TSynEdit` 加上它从来没有过的属性**的登记。这正是本文件开头写的
"把载荷归属到错误的类，会得到一个自信的错误答案"，只是从另一条路走进来。

修复方式不是"再加两个登记"，而是让扫描器**拒绝归属**它不建模的集合内容
（`CollectAngle` 状态），并把 `item` 行单独计数。

**④ 修 ① ③ 时我自己引入的第四个缺陷**，同样被注入矩阵抓到：`AngleDelta` 的
守卫 `(I + 1 <= Length(S)) and not (...)` 在 `<` 位于**行末**时为假，于是开括号
从未被计入，集合状态被置 0。**一个字符的边界情况，让刚修好的缺陷原样回来。**

### 17.7 反空转验证，以及"没重建就跑"这个老陷阱

新增 `tools/f3_probe_inject.py`：把上述每一处缺陷**逐个还原**，要求探针必须发现。

| 注入 | 断言 | 结果 |
|---|---|---|
| 集合守卫退回 2 字符 | `CollectionBlocks` 掉回 0 | ✅ 被拒 |
| `AngleDelta` 丢失行末 `<` | 内部属性重新被归属给 `TSynEdit` | ✅ 被拒 |
| 抽掉一条跳过登记 | `FormLfmProbe` 不再 14/14 | ✅ 被拒 |
| 从 `LCL_SUPPLIED` 抽掉 `TSynCppSyn` | 可转换数 45 → 44 | ✅ 被拒 |

四处全部按 **MD5 逐字节还原**。

> **工具自身也踩了一次"没重建就跑"**：首次运行时，`build_form_probe.ps1` 因注入
> 后数组越界而编译失败，而脚本继续去跑了**上一个**可执行文件——它通过了，于是
> 一个坏门禁被记成了好门禁。这正是 F3-SVG 方案记录的第四次"旧二进制"。因此
> **构建失败直接中止**，绝不接着跑；还原同样以 MD5 校验，而不是假定写入成功。
>
> **第二次是同一个陷阱的另一端，而且是自己造成的**：注入需要重建（改了源却不重建，量到的就是上一个二进制），但**还原之后没有任何人重建**。于是脚本以「4/4 被拒、
> 文件已还原」退出 0，却把 `FormLfmProbe.exe` / `PropRttiProbe.exe` 留在了**由被
> 注入的源编译出来的状态**。随后在干净树上跑探针，两个都失败了——读起来完全像是
> 本工具造成的回归。现已在退出前强制重建，并在注入矩阵之后复跑两个探针，确认
> 14/14 与 0 被拒。
>
> > **两次都是「旧二进制」，方向相反**：一次是构建失败后仍然运行，另一次是构建
> > 成功、但构建的是**错的源**。**一个以反空转为职责的工具，不能自己成为那个
> > 空转的来源**——这是本节唯一一处由本工具制造、而不是被本工具抓住的缺陷。

### 17.8 顺带修掉一处"永远不可能通过"的 CI 断言

CI 里 `RasterProbe` 那一步断言 `'rendered ok : 110'`，而探针打印的是**列对齐**的：

```
rendered ok      : 110          <- 冒号前 6 个空格
parse/raise fail : 7
```

在 `-notmatch` 下，该断言**每次运行都会 throw**，这个作业从来不可能变绿。
本地双向实测：字面量 `-notmatch` 为 `True`，`'rendered ok\s+:\s*110'` 匹配。

> **一个永远通不过的检查，和一个永远不会失败的检查，是同一种缺陷**——两者都
> 教会读者忽略这个徽章。已改为空白容忍，并顺带补上第三条断言（必须恰好 7 个
> 零弦载荷失败），把原来只钉住一半的不变量补全。

### 17.9 本批的诚实边界

* **`EditorOptFrm` 的 LFM 能加载，它的 Pascal 单元还不能对 LCL 编译。** 门禁全绿
  只说明**转换产物可加载**，不说明窗体**可用**（§16.5 的边界原样成立）。具体的
  障碍在 §17.3 已列出（token 枚举缺 4 个值），属于 F2 的 SynEdit 移植。
* **集合块与 `item` 行不由 `PropRttiProbe` 归属**，因此该探针**无法验证**它们。
  它们的权威是 `FormLfmProbe`：它直接流式化真实文件，读取器处理不了的集合会在
  那里带着读取器自己的消息失败（实测 14/14 通过）。计数照旧打印，只是从"硬失败"
  改为"报告"——否则这扇门将永远无法变红，而**永远变红的门禁等于没有门禁**。
* **`TSynGutter.Font` 的视觉差异仍未解决**：LCL gutter 无字体，跟随
  `TSynEdit.Font`，而驱动它的 `EditorOptFrm.pas:249-251` 属 SynEdit 移植。
* **本批没有动 Delphi 构建**：改动集中在 `Source/Fpc/`（`qa_check` 已豁免该目录）
  与 `Tests/FpcCoreTests/`。本机无 Delphi，`devcpp.exe` 仍未编译验证。
* **一处我自己差点写进文档的错误结论**：为核对 API 时用了**大小写敏感**的检索去查
  `WhiteSpaceAttribute`，全树 0 命中，几乎被记成"LCL 缺这个属性"。真实拼写是
  `WhitespaceAttribute`（小写 `s`），而 Pascal 标识符**大小写不敏感**，两棵树都声明了它。
  这是本项目记录过的"测量结果被重新推导"的又一例，形态是**检索式**而非结论。

### 17.10 复审：本批自身，以及它顺手暴露的三处漂移

F3-6 交付后做了一次全量复审（18 门禁 + 8 探针 + 注入矩阵全绿），并**专门回头审本批
自己改过的东西**。三处发现，两处当场修，一处列为下一步。

#### ① 调查询的"custom"标记与逐窗体判定不是同一口径（当场修）

`f3_form_survey.py` 的逐窗体判定走 `survey()`，本批已把 `LCL_SUPPLIED` 加进去；
但同一文件末尾的 control type roll-up 仍只查 `WIDGETSET`。同一次运行里，
`TSynCppSyn` 在逐窗体一栏是 OK、在 roll-up 一栏是 `<-- custom`。

顺带查出**一个更早就存在、规模更大的同类问题**：`survey()` 有意**排除根类**
（`comps[1:]`，因为窗体类是代码问题、不是窗体转换问题），而 roll-up 遍历的是
**全部**类型。于是**每个窗体自己的类**都被标成 custom。实测：

| | 修复前 | 修复后 |
|---|---|---|
| roll-up 中标 `<-- custom` 的类型 | **62** | **16** |
| 其中真正阻断过窗体的类型 | 16 | 16 |

16 与逐窗体判定逐一对上（`TCompOptionsFrame` / `TVirtualImage` / `TImageCollection` /
`TSVGIconImageList` / `TSynRCSyn` / `TControlBar` / `TdevFileMonitor` / `TClassBrowser` /
`TCppParser` / `TCodeCompletion` / `TdevShortcuts` / `TCppPreprocessor` / `TCppTokenizer` /
`TVirtualImageList` / `TSVGIconImageCollection` / `TSVGIconVirtualImageList`）。

修法不是"再查两个集合"，而是**标记直接从判定结果读**（累积 `blocking_types`），
不再重算——这与 F1-m-0 那次"`qa_check` 直接 import `mainform_baseline`"是同一条纪律。

> 这是本项目**第三次**"上报口径 ≠ 检查口径"（F1-g 的 `uses main` 计数、F1-m-0 的
> 第四项、本次）。三次的形状都是**同一文件内两处各自算同一个量**。

#### ② `f3_external_matrix.py` 跑 274 秒（当场修，137×）

实测该文件耗时 **274.2 秒**。定位：`find_external_types` 对**每一次控件出现**都调
`declared(t)`，而它每次都用一条正则扫**全部 491 个单元**：

```
1801 次控件出现 × 491 个单元 = 884,291 次全文件正则扫描
```

修法：把 `^\s*NAME\s*=\s*class` 一次性收成集合，之后是字典查找。

| | 修复前 | 修复后 |
|---|---|---|
| 耗时 | **274.2 s** | **2.0 s** |
| 输出 | — | **逐字节相同**（MD5 比对） |

两点必须说清楚：

* **输出逐字节相同**是硬证据，已存 MD5 比对。加速悄悄改了答案，比慢更糟。
* 谓词原本带 `re.IGNORECASE`。**这个不能丢**——Pascal 标识符大小写不敏感，树上确实
  存在 `TdmMain` 与其使用处 `dmMain` 并存的情形；改成大小写敏感的集合会把这类类型
  重新判成 "external"，**凭空造出一个不存在的阻断项**。因此集合的键统一小写。

顺带把 `usage_of` 的重复 `splitlines()` 提出来（语义逐字不变），但**这不是瓶颈**——
第一次我改错了地方：先怀疑 `usage_of`，改完仍是 330 秒，才回头去测真正的时间分布。
**"优化前先测"这条纪律在性能问题上同样成立。**

#### ③ 两个工具对"什么还挡着"给出不同答案（**未修，列为下一步**）

`f3_load_routes.py` 与 `f3_batch_plan.py` 都在回答"哪些窗体还挡着"，但：

* `f3_load_routes.py` 有一份 `RETIRED = {TSVGIconImageList, TVirtualImage,
  TCompOptionsList, TCompOptionsFrame}`，并**按"只对已产出 LFM 的窗体生效"**做减法
  （注释写明：全局减法会抹掉 `Packman/Main` 这类真实的生产端缺口）。
* `f3_batch_plan.py` **没有**任何退役减法，直接用 `survey()` 的原始判定。

于是同一棵树，`LangFrm` / `EnviroFrm` 在 route 工具里是 **CLEARED**（`TVirtualImage`
已于 F3-3 退役），在 batch 工具里却是 **BATCH B / 被 `TVirtualImage` 挡住**。

而方案文档 §"最终批次划分"那张表写的是 **B = 0**——它早于 F3-3/F3-4，**是一张
2026-10-06 的快照，但表头没有日期**，读起来像现状。

> **这正是本项目反复记录的那一类**："一处定义，杜绝'这个工具加了那个忘了'"。
> 退役清单目前有两份语义不同的副本。**正确修法**是把退役集合连同**每条的理由**放进
> `f3_form_survey.py` 作为唯一事实源，`f3_load_routes.py` 改为 import 它但**保留自己
> 的作用域限定**（只对已产出 LFM 的窗体生效），`f3_batch_plan.py` 同样 import。
> 详见下一步方案。

## 18. F3-7 的第一个结论是**否定**的：没有"便宜的窗体"可编译

§17 的下一步写的是"从最便宜的窗体起步，把'已转换'变成'可编译'"。**动手前先量，
量出来的结论推翻了这条排序本身。**

新增 `tools/f3_compile_cost.py`（纯测量，不是门禁），按**自研单元的传递 `uses` 闭包**
排序，而不是按控件数。

#### 18.1 控件数不是编译成本

| 窗体 | 控件 | 自研单元 | 自研 LOC |
|---|---|---|---|
| `IconFrm` | **6** | **81** | **49,223** |
| `ParamsFrm` | **8** | **81** | **49,223** |
| `EditorOptFrm` | **124** | **81** | **49,223** |

控件数从 6 到 124 相差 20 倍，**闭包完全相同**。§17 建议的"从 `ParamsFrm`（8 个控件）
起步"是错的——它是最便宜的**之一**，也是最贵的**之一**。

> **这正是 §13.6 那句话的一个具体反例**："还有几个窗体被挡着"是情绪指标。
> 同一个道理在这里叫：**"最便宜的窗体"和"最少控件的窗体"是两件事。**

#### 18.2 成本下限的成因：一条链，与 27 个入口

```
IconFrm → devcfg → MainUi → main        （实测的最短 uses 路径）
```

`main.pas`（**7,785 行**）在**每一个** CLEARED 窗体的闭包里。而：

* **全仓只有一个自研单元 `uses main`** —— `MainUi.pas`（这正是 F1 的成果）
* **但 27 个单元 `uses MainUi`**

即 `main.pas` 藏在 `MainUi` 的 27 路扇入之后。**反事实实测**：切断全部 27 条
`→ MainUi` 边之后——

| | 自研单元 | 最大自研 LOC | 到达 `main` 的窗体 |
|---|---|---|---|
| 基线 | **81**（13/13 完全一致） | **49,223** | **13 / 13** |
| 只切 `devcfg → MainUi` | 81 | 49,223 | 13 / 13（**无变化**） |
| 切断全部 27 条 `→ MainUi` | **42–44** | **27,647** | **0 / 13** |

**下限是真实的、可减的，但减不动**——只切 `devcfg → MainUi` 这一条**完全不产生
变化**，因为图是稠密的，`devcfg` 还有别的路走到 `MainUi`。

#### 18.3 由此得到的那条**架构**结论

> **反腐层在"引用"层面解耦了，在"编译"层面没有。**

F1 用 13 个批次把 `MainForm.*` 降到 0，`uses main` 降到 0，`MainUi` 成为唯一宿主。
这在**源码引用**上是彻底的。但 **`uses` 的 implementation 段仍然要求编译**，
所以 27 个消费者单元**编译期**依然耦合到那个 7,785 行的上帝窗体。

这不是 bug，是**架构的价码**，而且是这个价码第一次被量化：

| 层次 | 状态 |
|---|---|
| 源码引用耦合 | ✅ 0（F1 的成果） |
| **编译依赖耦合** | ❌ **27 个单元 → `MainUi` → `main.pas`** |

#### 18.4 对 F3-7 的处置（这是一个**否定结果**，不是一个里程碑）

原计划"编译一个窗体"**不成立为里程碑**：13 个窗体的成本下限都是同一个
**81 单元 / 49,223 LOC** 的闭包，而它由 `main.pas` 决定。**要编译任何一个窗体，
就得先编译 `main.pas`**——而 `main.pas` 正是 §13.3 已判定"排除出近期排期"的那一个
（8 类阻断，8 换 1）。

因此下一步**不是**"从便宜窗体起步"，而是**先把这个结论本身变成门禁**：

1. **已完成**：`tools/f3_compile_cost_baseline.json` 记录当前闭包下限
   （**81 单元 / 49,223 LOC / 13-of-13 到达 `main`**）；`--ratchet` 下限上升即失败，
   下降必须 `--write-baseline` 显式确认（与 `f3_form_ratchet` 同一纪律）。已接入 CI，
   并由 `f3_probe_inject.py` 注入一条 `uses` 边验证它**真的会失败**。
2. **它同时是 F3/F4 的排期输入**：这不是一个工具，是一份"编译一个窗体到底要做什么"
   的账单。任何人再问"下一步做什么"，答案在这里，不在估计里。
3. **若要真正降低下限**，唯一低杠杆切口是把门面**按层拆开**——让纯配置/领域单元
   只依赖一个不含 `main` 的窄门面。实测把 27 条 `→ MainUi` 全切可降到
   **42–44 单元 / 27,647 LOC、0/13 到达 `main`**，但那 27 条边**正是 F1 的成果**
   （消费者只经门面、不碰上帝窗体）。**这是设计决策，不是重构，应单独发一票。**

#### 18.5 本节抓到的两处自身缺陷

**① 工具自身的名字解析踩了同一个坑（而这个坑本项目已经记录过）。**
`unit_path` 原先用 `setdefault` 按 `rglob` 顺序建表，于是
`aboutfrm` 解析到了 `Source/Tools/PackMaker/Aboutfrm.pas`——**和
`Source/AboutFrm.pas` 同名但完全不同的两个单元**。后果不是数字偏一点，而是
**自信地报错方向**：量出 `AboutFrm` 闭包只有 1 个单元 / 48 行（走进了 PackMaker 的
无关窗体），于是它成了"最便宜的窗体"。

实测**全仓 8 个单元名歧义**：`aboutfrm` / `bzip2` / `config` / `frmmain` /
`libtar` / `main` / `uhighlighterprocs` / `umain`。其中 `main` 正是方案文档早就警告过
的"`Source/main.pas`、`Tools/PackMaker/main.pas`、`Tools/Packman/Main.pas` 三个不同
文件"。现已改为**显式报告歧义**并打印两边，而不是静默取一个。

**② `strip_lines` 的返回契约没有文档，猜了两次才对。**
第一版按 `(list, x)` 解包、第二版按 `list[str]` 用，都崩在第一个文件上；实测才发现
返回的是 `list[(str, bool)]`。两次都是**崩溃**而不是静默出错——这算是运气好，
但"契约要写在读者会看到的地方"这条已经补进注释。

> 这两处都不影响 §18.1–18.3 的结论（那些数字是在修复之后重测的），但它们各自
> 都曾经**制造**过一个看起来合理的错误结论。

#### 18.6 注入矩阵当场抓到本节自己的**第三处**工具缺陷

把 §18.4 的棘轮接入 `tools/f3_probe_inject.py`（注入一条 `uses` 边，要求闭包增长
被拒）之后，**第一轮就被判 MISS**——棘轮没抓到。查下来是工具自身的三个缺陷：

**① 分词器把带点的单元名劈开了。** `[A-Za-z_]\w*` 会把 `Core.Events` 切成 `Core`
和 `Events` 两个 token，两者都解析不到任何单元。症状**不是一个明显的错误**，而是
一列 `absent: 33` 的、看起来很合理的名字，以及**闭包明明加了一条边却不变**。改成
`[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*` 后，闭包从 **64 → 81 单元、40,838 → 49,223
LOC**——**17 个单元一直被漏掉**。

> **本节所有数字都是在修好之后重测的。** 但值得单独记的是：**没有任何一个数字自己
> 暴露了问题**。表格看着合理，是"注入矩阵报了一个 MISS"把它抓出来的——§17.7 那条
> 纪律的第四次兑现。

**② 前两次注入都选错了依赖，因此"棘轮抓不到"是假警报。**
`FileAssocs`、`Core.Events` **都已经在闭包里**——闭包饱和到大多数新增都不可见。
只有取**真正在闭包之外**的单元（最终选 `Theme`：一个项目类型单元去依赖 UI 主题，
本身就不该发生）才能测到棘轮。

> **一条容易被误读的结论**：若第三次仍选错，会得到"棘轮抓不到"的印象，然后可能
> 直接把这个棘轮删掉。**门禁没有被证明无效，它是被用错了方式测的**——而 `MISSED`
> 会被如实打印、不会被悄悄吞掉，正是这里的关键。

**③ 第一次注入的锚点是 `uses`，而 `ProjectTypes.pas` 里有两处**（interface 与
implementation）。`apply()` 拒绝执行，而不是随便挑一处——**这个拒绝是对的**，也正是
本文件可以相信的原因：陈旧模式是**硬停止**，不是空操作。

## 19. F3-7 第二步：用原生 LCL `TSynRCSyn` 解开 `DataFrm` 的高亮器阻断（2026-10-07）

§18 的结论是"没有便宜的窗体"，并且把编译下限变成门禁。但它同时留下一个**已经量好、
只差决定**的问题：`DataFrm.pas:26` 的 `uses` 里有 `SynHighlighterRC`，LCL 4.4 **没有**
这个单元。本文是那个决定，以及它的运行时证据。

### 19.1 三个选项，以及为什么只有第三个能长期成立

| 选项 | 代价 | 结论 |
| --- | --- | --- |
| **移植** vendored `SynHighlighterRC.pas` | 类声明 62 行，**完整单元 537 行**；且它是 Delphi SynEdit 的代码 | ❌ |
| 退化为 `TSynAnySyn` 空壳 | 语法高亮整体消失（属"功能损失"） | ❌ |
| **写原生 LCL 实现** | 735 行，只依赖 LCL 自己的 `SynEditHighlighter` | ✅ |

移植的代价是原生的**两倍**，而且那 537 行里有相当一部分依赖 Delphi SynEdit 的内部
约定——LCL 侧没有对应物。原生实现是唯一"**工作量更小且不背 Delphi 包袱**"的选项。

> 这里的"537 行"是 `f3_vendored_equivalence.py` 修好之后才拿到的数字。该工具此前
> 报的是类声明的 62 行——**两个数字都不是错的**，但混用会让人以为移植只要 62 行。
> 工具现在同时打印两者，并标注哪个是移植成本。

**类名保留为 `TSynRCSyn`**：`DataFrm.dfm` 写的就是 `object Res: TSynRCSyn`，
所以**不需要转换器 rename 规则、不需要改任何 `.dfm`**，只有单元位置变了。

**它不是"声明了没人用"的类**：`Source/DataFrm.pas:42` 声明 `Res: TSynRCSyn`，
`GetHighlighter`（:217-223）对任何 `.rc` 文件返回它，`UpdateHighlighter`（:197-206）
还会赋值 8 个 published 属性。

### 19.2 关键事实核对：LCL 确实没有 `synhighlighterrc`

`17.2` 曾断言它在 LCL 里不存在，那一节是**对的**，但当时只查了 `components/synedit/*.pas`。
本次连**已编译产物**一起核对：

```
components\synedit\synhighlightercpp.pp   有 TSynCppSyn
components\synedit\synhighlighterpas.pp   有 TSynPASyn
components\synedit\synhighlighterrc.*     不存在
units\x86_64-win64\win32\synhighlighterrc.ppu   不存在
```

> 注意 `.pp` 扩展名：`17.1` 记录了"只搜 `*.pas` 会以为 LCL 没有 `TSynCppSyn`"这个
> 同款陷阱。这次连 `*.pp` 和 `.ppu` 一起查，就是为了不重复它。

### 19.3 运行时证据，以及"能加载"这个弱主张为什么不够

`Tests/FpcCoreTests/syn/SynRcProbe.lpr`（39 项断言）**不是**"构造函数没崩"级别的检查：

- 真实 `.rc` 文本 → **54 个 token、7 种不同 kind**
  （`directive comment identifier space keyword number string`）。
  **均匀返回 `tkUnknown` 的空壳做不到这一点**，这是本探针存在的理由。
- 跨行 `/* ... */`、`//` 到行尾、裸 `/` 是符号而非注释、十六进制、十进制后接字母、
  **双引号转义 `"a""b"` 是单个字符串**、指令在字符串前停止、
  `NAME { "res\name.rc" }` 是**单个** identifier。
- 8 个 published 属性**可赋值**。

### 19.4 探针自己抓到的四个缺陷（以及三个"断言写反了"）

这一节记录的是**探针的错误**，因为它们比高亮器的错误更值得留档——一个只会报健康的
探针比没有探针更糟。

1. **`SYN_ATTR_DIRECTIVE` 从 `GetDefaultAttribute` 里漏掉了。**
   8 个属性全部"可赋值"的检查**照样通过**，而 `DirecAttri` 对基于索引的查找
   永远返回 `nil`。也就是说：该属性可赋值、已发布、`UpdateHighlighter` 也在拷贝，
   **却在任何非 `GetTokenAttribute` 的路径上从未被使用**。
   > 教训：**"属性存在"和"属性可达"是两件事**，只有后者的检查才有效。已补 9b 项断言。

2. **自测的两条断言是**反**的。** 原写法 `(Length(Kinds) = 0) or (AllUnknown = 0)`，
   对一个产出 4001 个 `tkUnknown` 的坏高亮器**判为失败**——而" runaway guard 触发"
   恰恰是**期望结果**。另一条名为"空 token 流不被静默接受"、实际断言
   `Length(Kinds) = 0`，与自己的名字相反。已重写为"坏高亮器必须**不匹配**真实期望"，
   并把检查名改成实际发生的事（该 stub `GetEol` 恒为 `False`，永远不是空流）。

3. **自测缺少反空洞性检查。** 只用坏高亮器构造的自测，**一个永远判失败的匹配器
   也能通过**。因此**反空洞性用例放在坏用例之前**：真实高亮器必须满足标尺。

4. **`GetDefaultAttribute` 是 `protected`。** 探针里直接调用得到
   `no member`——**编译器是对的**。解法不是削弱检查，而是用 `TProbeRCSyn` 子类
   合法暴露它。（顺带发现签名带 `Index: integer` 参数。）
   > 副作用：`H.ClassName` 变成 `TProbeRCSyn`，所以"类名必须是 `TSynRCSyn`"改查
   > `TSynRCSyn.ClassName` + `H is TSynRCSyn`。这是探针脚手架造成的**假失败**。

**反空转**：手工删掉 `SYN_ATTR_DIRECTIVE` 分支后重建，探针
`exit=1` 且精确报 `every SYN_ATTR_ index resolves to its attribute`；
恢复后 `exit=0`。**门禁能失败，已验证。**

### 19.5 两个高亮器本身的行为修正

| 缺陷 | 症状 | 修正 |
| --- | --- | --- |
| `DoNext` 到达行尾未产出 token 时不置 `tkNull` | 块注释吃到行尾后 `tkComment` **无限重复**（探针以 4001 token 抓出） | 行尾显式发布 `tkNull` |
| 探针每行调 `ResetRange` | 跨行块注释状态被抹掉 | `ResetRange` 只在整段文本前调一次——它属于**重扫**，不属于线性遍历 |
| `"a""b"` 被切成两个字符串 | RC 里带转义引号的 caption 全错 | 双引号按转义处理，**整串一个 token** |
| `NAME { ... }` 要求 `{` 紧跟标识符 | 真实文件里 `IDB_ABOUT { "res\about.rc" }` 有空格，于是被切成 **7** 个 token | 允许并吞掉中间空白 |

> 三条**探针期望**也曾经写错（把 bug 编码成了期望），已更正并注明原因：
> 跨行注释的行首空格**在**注释内；指令 token **含**其后空白；`SetLine` 收到的行
> **不含行尾符**，所以 token 文本里没有 `#13#10`。
> **一个把当前输出抄下来的期望，等于把 bug 抄进期望。**

### 19.6 编译下限基线**上移**了，这是正确的

原生单元进入了 `DataFrm` 的闭包，`f3_compile_cost.py --ratchet` 如实报出增长：

```
max_own_units   81 -> 82
max_own_loc     49,223 -> 49,959
```

这**不是回归，而是本次交付物本身**：735 行换来一个原本必须移植 537 行 Delphi 代码
才能得到的类。它是 `--write-baseline` **显式**记录的，不是自动接受的——
§18.4 那条纪律在这里第一次**因为成功而触发**。

> 同时这恰好构成对 §18 结论的一次压力测试：`DataFrm` 的闭包变了，
> 而 13-of-13 仍然全部到达 `main.pas`——**门面那条边没有被绕开**。

### 19.7 `DataFrm` 仍然**未**解锁（诚实边界）

解除高亮器阻断后，`DataFrm.dfm` 仍被 **`TImageCollection`（2 处）**与
退役清单里的 `TSVGIconImageList` 阻挡。**本节不解锁任何窗体。**

### 19.8 编译下限与门面的关系：**暂不反转 `MainUi`**

§18.4 把"要不要切 27 条 `→ MainUi`"标为"应单独发一票"。这一节给出建议：

**建议：先攻 `main.pas` 的 Pascal 侧可编译性，暂不反转门面。** 理由：

1. 门面反转的收益（42–44 单元 / 27,647 LOC / 0-of-13 到 `main`）是**实测**的，
   但它要付出 F1 刚建立的那 27 条边——**消费者只经门面、不碰上帝窗体**。
2. `main.pas` 阻断是 **8 类换 1 个**（`TControlBar`、`TClassBrowser`、
   `TCppParser`…），本质是**依赖收敛**，与门面方向无关。
3. 因此门面反转是 `main.pas` **确实无法推进时的后备方案**，不是并行的第二件事。
   并行做等于同时改两处耦合，而两处耦合的验证手段目前都还没有。

`main.dfm`（565 控件 / 8 类）仍然延期：它只在 `main.pas` 可编译之后才有意义。

## 20. F3-8：`main.pas` 的 37 个带点单元里，**13 个是真工作，22 个只是拼写**（2026-10-07）

§19.8 建议"先攻 `main.pas`、暂不反转 `MainUi`"。这条建议要变成排期，就得先回答
一个问题：**`main.pas` 到底有多难？**

§18 的答案看起来很难：13 个窗体的闭包都经过 `main.pas`，而 `main.pas` 的 `uses` 里有
48 个**带命名空间点**的单元，全部"absent"。如果照字面读，那是 48 个单元的移植工作量。

**这个读法是错的，而且错在两个方向上都发生过。**

### 20.1 结论

`main.pas` 闭包中 37 个 absent 的带点单元，分成三类：

| 类 | 数量 | 含义 |
|---|---|---|
| **0. 已可解析** | **2** | FPC 就用这个带点名字发布（`Generics.Collections`、`System.UItypes`） |
| **A. 仅拼写** | **22** | 去掉前缀就是 FPC/LCL 的单元。**不写新代码** |
| **R. 已在我们自己的单元里** | **1** | `Vcl.VirtualImage` → `LclVirtualImage.pas`（F3-3 已做） |
| **C. 是控件不是单元** | **0** | 名义上属于我们、但不能出现在 `uses` 里 |
| **B. 真缺失** | **12** | 哪都没有。**这才是工作** |

**25 / 37（68%）不需要写任何新代码。真正的工作量是 12 个单元。**

> ⚠️ **本表描述的是解析状态，不是行动方案**，而且两件事必须分开读：
>
> - **R 行**当时写的是"只差改 `uses`"，**这个行动方案已被 §21 证伪**——
>   那 4 处 `uses` 在 Delphi 树里，改动会破坏 Delphi 构建。实际交付的是
>   **一个 FPC 侧 shim**，不是 4 次改名。
> - **A 行（22 个）"不写新代码"是真的**（单元本来就在），但 **§22 实测表明
>   shim 机制对它们几乎不适用**：22 个里只有 **1 个**满足安全可行条件。
>   **"不需要新代码" ≠ "可以用 shim 解决"。**
>
> 本节的测量没有错；被推翻的是据此推导的行动。**这是"测量"与"计划"必须分开归档
> 的一个具体例子。**

### 20.2 "仅拼写"这个判断是**编译验证**的，不是查表

关键在于不能只比较名字。`Vcl.Themes` 的尾巴是 `themes`，LCL 确实有 `themes` 单元——
但 `uses Themes` 在这个 widgetset 下能不能链接，**只有编译器知道**。

所以 `tools/f3_namespace_alias.py` 会**生成一个程序**，把所有 A 类单元去前缀后一起
`uses`，然后**真的编译它**：

```
VERIFICATION -- compile one program using ALL of group A, prefixes dropped
   PASSED: 22 unit(s) compile. Group A is spelling, not work.
```

如果某个单元归进了 A 却编译不过，工具会打印编译器的原话并声明上面的表**不可信**。

> 这个设计和 `SynRcProbe` 是同一个：**"能加载"是个比想象中弱得多的主张。**
> §17.6 记录的正是"审计工具自己在输出健康数字"，所以这里不给自己留这条路。

### 20.3 这张表被三次修正，每次都错在**更有说服力的方向**上

这一节是本节最值得留下的部分。三次都是**每一行单独看都合理**，错的是整体方向。

**① 按源码文件名统计 → 声称 `SysUtils` / `Classes` / `Math` / `Forms` 都不存在。**
`.pp` 是 **3** 个字符、`.pas` 是 4 个，统一 `f[:-4]` 会把 `forms.pp` 变成 `form`。
于是**九个 FPC 必然提供的 RTL 单元**被报成"真缺失"。
> 修法：按**已编译的 `.ppu`** 统计，而不是源码。`.ppu` 才是"为这个 target 和
> widgetset 构建过"的证据，源码只是一个承诺。

**② 补了 FPC 的 units 树 → 33%。** 上一版只扫 LCL/components，而 `SysUtils` 在
`fpc\...\units\...\rtl`——**另一棵树**。结论从 56% 掉到 33%，方向是**把工作说得更重**。

**③ 又漏掉 FPC 自己的命名空间单元 → 13%。** 只比尾巴，把 `Generics.Collections`
判成"真缺失"，而 FPC 就是用这个名字发布它（`rtl-generics`）。**一个已经存在的单元被放
上了移植清单。**

**④ 去掉 `classify()` 过滤 → 混进 `System.UItypes`。** 按"带点"一刀切，把这个
**本次构建已经编译好**的单元也扫了进来。"真缺失"这张表的全部含义是"这得我们写"，
而这里什么都不用写。

> **三处修正，结论依次 33% → 56% → 65% → 59%(A)/13(B)。**
> 更值得记的是：**没有一版的数字自己暴露了问题。** 三张表都能打印、都能自洽、
> 都能支持一个看起来很合理的结论。是"分类的定义"每次都必须重新检查，才把它们抓住。

最终分类里有**一条断言**：五类必须构成 absent 带点单元的**划分**，否则直接报错。
> **一个加起来不等于 100% 的结论，比没有结论更糟。**

### 20.3b 第五类（R）是本节最有用的一条发现

`Vcl.VirtualImage` 没有对应单元、尾巴也不是 LCL 单元——按"两类分法"它落在
**真缺失**里，读起来就是**有人得去写它**。

**没有人要写。** `Source/Fpc/UI/Controls/LclVirtualImage.pas` 从 §14（F3-3）就在，
转换器里也早有 `TVirtualImage -> TLclVirtualImage`。剩下的只是**在 4 处 `uses` 里
把单元名改掉**（`DataFrm` / `EnviroFrm` / `LangFrm` / `main`）。

> **把已完成的工作重新排进待办，比低估成本更贵**：它会让路线图看起来永远做不完。

这一类必须是**查出来的**，不能靠命名直觉猜。它问的是"转换器已经把这个类映射到某个类了，
那个类对应的单元在不在我们仓库里"——答案在 `f3_dfm_to_lfm.py` 的 `CLASS_RENAME`
里，是**一个有记录的唯一答案**。

**而 R 类自己也被抓到两次错：**

1. **按子串匹配**把 `System.ImageList` 也判成 R（因为 `TLclSvgImageList` 结尾是
   `ImageList`）。但 `TLclSvgImageList` 不是 Delphi 的 `System.ImageList`。
   > 更值得注意的是：**工具打印了它匹配到的文件**，所以这条错误是**肉眼可读的**，
   > 仍然被提交了。**打印证据不等于验证证据。**
   > 修法：要求**转换器的源类名**与该单元名对应，而不是目标类名包含它。

2. **C 类按文件名匹配**，把 `Vcl.ImageCollection` 判成"我们的控件"。
   而 `ImageCollectionData.pas` 里声明的是 `TImageCollItem` 和
   `TImageCollectionRec`——**两个 record**，`Source/Fpc` 下**根本没有
   `TImageCollection`**。
   > 修法：查**类声明**（`T… = class`），不查文件名。
   > 这正是 `DataFrm` 的既有阻断项——§19.7 说它**未**解锁，这里是同一个事实的
   > 第二个独立读数。

### 20.4 12 个真工作（按性质分组，不是按名字）

| 单元 | 性质 |
|---|---|
| `Vcl.WinXCtrls` / `Vcl.WinXPanels` | LCL 无对应，需要真移植或替代 |
| `Vcl.Imaging.pngimage` | 需接到 LCL 的 PNG 路径 |
| `System.AnsiStrings` / `System.IOUtils` / `System.Threading` | 小工具级缺失 |
| `System.Actions` | LCL 有 `ActnList`，**接近别名但需确认语义** |
| `System.ImageList` / `System.Generics.Collections` | 名字接近现有单元，**但都不是同一个东西**（见 §20.3b 第 1 条） |
| `Vcl.ImageCollection` / `Vcl.BaseImageCollection` | `DataFrm` 的**既有**阻断项，同一条线 |
| `Vcl.VirtualImageList` | 与已完成的 `TLclVirtualImage` 相邻，但**列表 ≠ 单控件** |

> **注意 `Vcl.VirtualImage` 已经不在这张表里**——它在 R 类（§20.3b）。

**这里已经有一个可执行的结论**：`Vcl.VirtualImage` 归入 R 类（§20.3b），**不是移植**。

所以 12 个真工作里，真正"从零开始"的只有这些：`System.Actions`、`System.AnsiStrings`、
`System.Generics.Collections`、`System.IOUtils`、`System.ImageList`、`System.Threading`、
`Vcl.Imaging.pngimage`、`Vcl.WinXCtrls`、`Vcl.WinXPanels`（**9 个**，小工具或真移植）。
另外 3 个（`Vcl.ImageCollection` / `Vcl.BaseImageCollection` / `Vcl.VirtualImageList`）
**属于 `DataFrm` 的既有阻断项**，与 §19.7 是同一条线，**不是新增负担**。

### 20.5 门禁与反空转

`tools/f3_namespace_alias.py --ratchet` 锁定 **12 / 0 / 1 / 22 / 2** 五个数，**只增长即失败**，
下降必须 `--write-baseline` 显式确认（与 `f3_compile_cost.py` 同一纪律）。

注入矩阵新增第 **8** 条：把单元搜索指向一棵**空目录**，要求 A 类整体塌进 B 类、
计数上移、门禁失败。

> 第一次跑它**没有通过**，而且错得很有意思：注入锚点写的是那条路径字符串本身，
> 而它在 `UNIT_DIRS` 和 `FU_ORDER` 里**各出现一次**。陈旧模式守卫**正确地**报了
> "occurs 2 time(s), expected 1" 并停机——但那不是陈旧，是**歧义**，结果整个矩阵
> 无声死掉。改成锚在 `UNIT_DIRS = [` 上。
>
> 顺带修了注入框架的一个真缺陷：`MISSED` 时只打印含 `FORK`/`HOLE`/`RESULT` 的行，
> 所以命名空间棘轮失败时**一行证据都没有**，MISSED 报告成了一句空断言。

### 20.6 CI 位置：这一条**必须**在有工具链的 job 里

`--ratchet` 会**真的编译**那个验证程序，所以它不在 `qa-gate-profiles`
（纯文本、ubuntu、无编译器）里，而在 `lcl-svg-runtime`（windows + Lazarus）里，
与其它棘轮和 `SynRcProbe` 并列。

> 这是本节唯一一个"看起来可以省掉"的安排：如果只做名字比较，就可以塞进纯文本 job。
> 但那正是 §20.2 要避免的事。**分类的可信度来自它验证了，不是来自它跑得快。**

### 20.7 对 §19.8 的影响：结论不变，理由更硬了

§19.8 建议**先攻 `main.pas`、暂不反转 `MainUi`**，理由是"`main.pas` 的阻断是依赖
收敛，与门面方向无关"。本节**没有推翻**它，只是把"有多难"从"48 个 absent 单元"
改成"**25 处无需新代码 + 12 个真工作**"。

- 这**降低了** `main.pas` 的估计成本 → 更支持先攻它，而不是反转门面。
- 12 个真工作里 **3 个**与 `DataFrm` 既有阻断重合，**9 个**是小工具级缺失。
- 且其中 **1 个根本不用做**——`Vcl.VirtualImage` 在 F3-3 就已完成（§20.3b）。
  这条发现的直接收益是：**一个已完成的类不会回到待办列表上**。

**诚实边界**：本节**没有**让任何窗体变得更接近可编译，**没有**改任何 `.pas`，
唯一新增的代码是那个一次性验证程序（编译在临时目录，不入库）。
门禁锁定的是**分类**，不是进度。

## 21. F3-8 续：**FPC 侧兼容 shim** 打通门面，且不动 Delphi 源码一个字符（2026-10-07）

§20.3b 有一条发现当时只能**改 4 处 `uses`** 来兑现：`Vcl.VirtualImage` 落在 R 类
（我们已有 `LclVirtualImage.pas`，F3-3 就写完了）。

但那 4 处 `uses` 全在 **Delphi 树**（`Source/*.pas`，`main.pas` 还在 `devcpp.dpr` 里）。
把它们改成 `uses LclVirtualImage` 会**把一个只存在于 FPC 树的单元塞进 Delphi 编译器
的搜索路径**——而 `tools/qa_check.py --profile delphi` 这个门禁存在的全部意义就是拦住
这件事。

所以**改 `uses` 这个方案本身是错的**。本节是它的替代方案，并且顺带证明了更强的一句话：
> **门面可以通过 FPC 侧兼容层扩展，完全不污染 Delphi 源码树。**

### 21.1 做法：保留源码可见的单元名，让 FPC 搜索路径提供实现

这是 F3-6 `TSynRCSyn` 已经用过的机制，只是当时没人注意它还能这样用：

| | Delphi 树看到的 | FPC 树看到的 |
|---|---|---|
| `TSynRCSyn` | `Source/VCL/SynEdit/Source/SynHighlighterRC.pas` | `Source/Fpc/UI/Controls/SynHighlighterRc.pas` |
| `TVirtualImage` | VCL 自带 | **`Source/Fpc/UI/Compat/Vcl.VirtualImage.pas`（新增）** |

`Source/main.pas` **一个字都没改**，仍然写着 `uses Vcl.VirtualImage`；FPC 侧 `-Fu`
把那个名字解析到我们写的 shim。新文件 68 行，**0 个新类**。

### 21.2 决定成败的一个细节：**必须是类型别名，不能是子类**

这是**编译两种形状**定出来的，不是读代码看出来的：

```pascal
type TVirtualImage = class(TLclVirtualImage) end;   →  Error: Incompatible types:
                                                            got "TLclVirtualImage"
                                                            expected "TVirtualImage"
type TVirtualImage = TLclVirtualImage;              →  编译、运行、身份保持
```

子类是**另一个类型**。DFM 流式化会把基于 `LclVirtualImage` 的组件**赋值**到
Delphi 树声明为 `TVirtualImage` 的字段（`EnviroFrm.pas:104`、
`main.pas:586`），子类让这一步变成类型错误。**别名让两个名字指向同一个类型**，
这正是流式化需要的。

> 运行时验证用的就是这两个字段的真实形状，赋值后确认**同一个实例**经两个名字都可达。

### 21.3 shim 契约：四条不变量，**逐条被打破验证**

写成散文的不变量不是不变量。所以每一条都做了"故意破坏 → 门禁必须报错"：

| # | 不变量 | 破坏方式 | 捕获 |
|---|---|---|---|
| 1 | 存在且声明该单元名 | 声明成 `unit SomethingElse` | ✅ |
| 2 | 位于 `Source/Fpc/` 之下 | 放到 `Source/ShimMisplaced.pas` | ✅ |
| 3 | 以**别名**重导出到真实符号 | 别名指向不存在的类型 | ✅ |
| 3b | 不得新声明一个类 | `= class(...)` | ✅ |
| 4 | Delphi 树仍引用该名字 | 3 处引用全改掉 | ✅ |

**这个过程本身抓到三个缺陷，都值得留档：**

**① 不变量 2 一开始是**不可违反**的。** `shim_for()` 当时只扫 `Source/Fpc`，
所以"放错位置"的 shim **根本找不到**，那条负责拒绝它的检查**永远不会被执行**。
**一个没人能违反的不变量不是不变量。** 改成扫整个 `Source/`（排除 `VCL`/`Archive`），
不变量 2 才真正可达。

> 排除 `VCL` 是必须的：vendored 树里**真的**有 `unit SynHighlighterRC`。把它当成
> 我们的 FPC shim 会让整个机制的意义**反转**。

**② 不变量 1 被计数棘轮"抢跑"了。** 契约检查原本排在计数之后，且计数一失败就
`return 1`。而"声明错名字"**同时**会改变计数，于是计数路径先返回，**契约消息永远
不打印**。失败被检测到了，但**理由是错的**——而一个只在其余检查都通过时才说话的契约，
等于没有被执行。现在两组失败**一起报告**。

**③ 不变量 4 的测试一开始什么都没测。** 它只改了 `LangFrm.pas` 一处，
而 `EnviroFrm.pas` 和 `main.pas` **仍在引用**该名字——不变量**正确地通过了**，
测试却宣称它在测"引用是否消失"。**一个测不到东西的测试比没有测试更危险**，
因为它显示绿色。

### 21.4 历史测量不许被改写：shim 范围是**相加**的，不是**覆盖**的

这里我犯了一个错，值得按顺序记：**先跑了 `--write-baseline`**，于是基线里
`renamed` 从 `[Vcl.VirtualImage]` 变成 `[]`——**历史测量被洗掉了**。这与"不要篡改
历史分类"直接冲突。

改法不是"重新写一遍数字"，而是让基线**同时**承载两件事：

```json
"main_closure_own_units": 82,          ← 冻结的测量值（shim 存在之前）
"shims": { "Vcl.VirtualImage": { "scope_added": { "own_units": 1, ... } } }
```

棘轮算的是 **历史值 + 已声明 shim 范围**，并且：

- **shim 必须存在才给范围。** 第一版无条件发放，于是**删掉 shim 也能过**
  （基线说 +1，树里没有那个单元，棘轮判定 `82 <= 83` 通过）。
  **一个背后什么都没有的额度，就是一个没有意义的额度。** 现在逐个校验存在性。
- **单元数下降必须由 shim 解释。** 否则报"无法解释的改善"，而不是自动接受。

> **一个不需要写代码的改进，允许通过；一个由 shim 解释的下降，打印出解释；
> 一个无人解释的下降，直接失败。**

### 21.5 这一节解开的**机制**问题，比解开的那一个单元重要

`Vcl.VirtualImage` 本身只是 1 个单元。但本节证明的是**一条可复用的边界**：

> **Delphi 树保持原样，源码可见的单元名不变，FPC 搜索路径供给实现。**

这条边界对 §20 的 A 类（**22 个仅拼写**）同样适用——而且**很可能**比逐个改写更便宜。
但**本节不推广**：22 个 shim 同时落，棘轮的变化就**无法归因**了。
§20.6 那条纪律在这里第三次兑现——**一次只动一个，才有 before/after。**

### 21.6 诚实边界

- `DataFrm` **仍未解锁**（`TImageCollection` 系列，见 §19.7 / §20.4）。
- 本节**没有**让任何窗体更接近可编译；`main.pas` 的 12 个真工作一个都没少。
  shim 满足的是 §20 里**原本就不需要写代码**的那一项。
- A 类 22 个 shim **一个都没做**（按决定）。
- Delphi 树 `git diff` 为**空**，已核验。

> 本节的产物是**一个 68 行的文件 + 一条可复用的边界 + 四条被验证的不变量**。
> 不是 22 个文件的批量改动。

详见 `tools/f3_namespace_alias.py` 的 `check_shim_invariants()`。

## 22. F3-8 收尾：**shim 泛化假设被证伪**，`Vcl.VirtualImage` 是特殊成功案例（2026-10-07）

§21 建立了 shim 机制并在**一个**单元上验证成功。诚实的下一步不是推广，而是问：
**这个机制能覆盖 §20 的 A 类（22 个仅拼写）吗？**

**答案是否定的。** 本节是那次实验的结论，**没有写任何 shim、没有改任何源码**。

### 22.1 决定性事实：FPC **没有**传递性接口可见性

`Vcl.VirtualImage` 之所以能用 shim，是因为**只命名了一个符号，且那个符号是类型**。
同样的机制并不普适，而原因**是测出来的**：

```pascal
unit Vcl.Forms;
interface
  uses Forms;              { 这不够 }
implementation
end.
```
```
t.pas(4,8) Error: Identifier not found "TForm"
```

限定别名可以（`TForm = Forms.TForm;`，实测编译并运行）。但**只有类型可以**：
重导出 *例程* 必须重复 `external 'dll' name '...'`；*变量* / *常量* 需要重新声明。

> 所以"能不能 shim"这个问题，真实形式是：**需要多少个符号、分别是哪一类**。

### 22.2 分类结论（`tools/f3_shim_feasibility.py`，逐名测量）

| 分类 | 数量 | 下一步 |
|---|---:|---|
| **1. 可安全 shim** | **1** | `Winapi.Messages`（1 个 type，**单独评估，不视为下一项实现**） |
| **2. 已可解析** | **0** | — |
| **3. 不适合 shim** | **18** | 需要 routine/var/const，走各自的实际兼容路径 |
| **4. 真正无需符号** | **1** | `System.Math`（符号面实测 120 个，`main.pas` 引用 **0** 个） |
| **5. 不确定** | **2** | `System.SysUtils` / `System.WideStrUtils`，**暂停，不猜** |

**shim 泛化假设已被证伪，实验完成。** 门面应转向**逐名兼容策略**，不是批量 shim。

### 22.3 本次最值钱的防错结论：**证据提取失败 ≠ 符号不存在**

这个工具**第一次运行的结果是危险的**，而且如果被采纳，会**批准删除真实工作**。

第一次跑出来 5 个名字被判为"**QUESTIONABLE — 该单元没有任何符号被引用，
仅凭 uses 条目不足以立项**"，其中包括 `System.SysUtils`。

**那是提取器的产物。** FPC 的 RTL 单元是**空壳**：`sysutils.pp` 内容是
`{$I sysutils.inc}`，`classes.pp` 是 `{$I classes.inc}`。不跟随 include 就只能看到
**5 个**和 **0 个**导出符号——于是每一个 RTL 名字都成了"未使用"。

> **这是本工具唯一不能犯的错误方向**：它会把"要做的真工作"判成"不必做"。
> 其余方向（把 trivial 判成麻烦）只是浪费时间。

**两条护栏现在挡住了这个方向：**

1. **可疑的小符号面 → 拒绝分类。** 尾巴单元只暴露 <25 个符号时，
   那是"提取失败"的证据，不是"单元未被使用"的证据。
   （正是这条拦下了 `System.WideStrUtils`。）
2. **`{$I}` 解析歧义 → `INDETERMINATE`，不猜。** FPC 为多个平台各备一份同名
   `.inc`（`execd.inc` 有 morphos、amiga …），"取第一个命中"会把**别的平台的声明**
   注入进来当证据。所以 `System.SysUtils` 报 INDETERMINATE 而不是被分类。

> **`INDETERMINATE` 是一个正式结果，不是缺口。** 要可靠判定需要平台条件求值器。
> **保留未知，好过为了让表格好看而猜。**

`System.Math` 的第 4 类是**实测**的：`math` 导出 120 个符号，`main.pas` 对
`Pi` / `Max` / `Min` / `Sqrt` / `Abs` / `Odd` **一个都没用**，且 `uses` 里确实列了它。
这可以单独考虑移除该 `uses` 条目——**但删 Delphi 树的 `uses` 与本节的边界冲突，
需要单独决策。**

### 22.4 facade 估算正式改写

**不要再说：**

> `main.pas` 有 22 个名字可以做 shim。

**应该说：**

> **22 个 dotted names 中，只有 1 个满足当前 shim 机制的安全可行条件；18 个需要
> 其他兼容机制；1 个经符号面实测为未使用；2 个尚不能可靠判定。**

这比"22 个 shim"精确得多，而且它的**精度来自测量而不是乐观**。

§20 的测量（37 → 2 / 22 / 1 / 0 / 12）**依然成立**，因为它描述的是**解析状态**；
被推翻的是**行动方案**——"仅拼写"**不等于**"shim 可行"，`Vcl.VirtualImage` 的成功
是**特例**，不是模板。

### 22.5 `Vcl.VirtualImage` 的价值反而更高了

它现在定义了一条**实测边界条件**：

> **单一 type alias 可行；跨 routine / var / const 的重导出不行。**

这条边界比"我们有一种 shim 机制"有用得多——它**告诉排期哪些名字不要用这条路**，
而这正是 §20 无法回答的问题。

### 22.6 本节状态：测量已完成，未实施

- **没有**写 A 类 shim（一条都没有）。
- **没有**改 Delphi 树（`git diff` 为空）。
- **没有**提交（HEAD 仍 `756e0bd`，0 未推送）。
- 两个 `INDETERMINATE` 留在报告里，等一个可靠的 platform-conditional include
  evaluator。**不要为了让表格完整而猜。**

> ⚠️ **本节的分类表已被 §23 作废，行动项 6（`Winapi.Messages`）已被关闭。**
>
> §22.2 那张 1 / 0 / 18 / 1 / 2 的表是**用源码文本算出来的**，而 §23 实测那个读者
> **读的是别的平台的单元**（`SysUtils` 与 `Classes` 来自 `rtl\amicommon`，即 Amiga；
> `Messages` 来自 `lcl\nonwin32` 空壳）。所以本节的表**保留在这里作为历史记录**，
> 它的测量过程没有被改写，只是它的结论不再被引用。
>
> §22.3 那条防错结论（**证据提取失败 ≠ 符号不存在**）**依然成立**，而且被 §23 用另一种
> 方式兑现：不是更用力地解析源码，而是换一个**不会坏**的证据源。
> §22.6 的最后一行所要求的"一个可靠的求值器"，在 §23 里**已经不需要了**——
> `ppudump` 一直都在。

## 23. F3-8 续二：符号面改用**编译器自己的记录**，§22 的整张表随之作废（2026-10-08）

§22 留下两个 `INDETERMINATE`，并把缺的那个工具写成了"platform-conditional include
evaluator"。**诊断是对的，处方是错的**：机器上已经有那个求值器，而且它是决定性的那一个。

### 23.1 处方错在哪：`.ppu` 就是那张符号面

```
ppudump -VS <unit>.ppu        # 接口符号表，带 kind
```

§20.3 已经写下过这条原则——"`.ppu` 才是'为这个 target 和 widgetset 构建过'的证据，
源码只是一个承诺"——并把它用在**单元是否存在**上。这一节把它用到**符号面**上，
而这正是手写 `{$I}` 跟随失败的地方。

新增 `tools/f3_ppu_surface.py`。它**不改分类规则**：`f3_shim_feasibility.classify()`
的证据来源被做成参数，同一套规则跑两遍，只换证据。

### 23.2 选哪个 `.ppu`：**问编译器，不猜**

`sysutils.ppu` 有三份（`rtl` / `rtl-objpas` / `rtl-unicode`，按语言模式各一份），
猜错就是静默地描述另一次构建。所以工具用项目自己的 flag 编一个探针，
以 `-vt` 读回 `PPU Loading`：

```
PPU Loading ...\rtl\sysutils.ppu
PPU Loading ...\rtl-objpas\widestrutils.ppu
```

**实测而非假设**：回来的就是 `rtl\` / `rtl-objpas\` / `fcl-base\`，没有 `rtl-unicode`。

### 23.3 §22 的表整张作废，原因是三个都朝危险方向的缺陷

#### ① 它读的是**另一个平台**的那份单元

`compiled_unit_paths()` 用 `setdefault` 建表，`rglob` 先给谁就算谁：

| 名字 | 实际打开的文件 |
|---|---|
| `SysUtils` | `rtl\amicommon\sysutils.pp`（**Amiga**） |
| `Classes` | `rtl\amicommon\classes.pp`（**Amiga**） |
| `Messages` | `lcl\nonwin32\messages.pp`（**非 Windows 的空壳**） |

**这张表里最重要的三个名字，是照着一个本项目根本不编译的平台判定的。**
`Winapi.Messages` 为什么会被判成"未被引用"——全部答案就在这里：空壳里几乎没有声明。

#### ② 它把**类成员和 record 字段**当成单元符号

声明正则在任意嵌套深度匹配，于是 `TThread = class` 里的 `constructor Create;`
变成一个叫 `Create` 的 routine，`X : Longint;` 变成一个叫 `X` 的变量。
实测 22 个名字上共 **177** 个这种符号，而 `Create` / `Assign` / `Clear` / `Add`
几乎出现在任何文件里，于是它们在消费端"被用上了"。

> 机制有硬证据，不是断言：
> `lcl\printers.pas:224` `TPrinter = class(TObject)`、`:114` `procedure BeginDoc; virtual;`；
> `rtl\objpas\classes\classes.inc:147` `constructor Create;`。
> 类成员属于**类自己的**符号表，随类型一起来，shim 从不需要单独命名它们——
> 这正是 `.ppu` 接口符号表里没有它们的原因。

#### ③ `strip_comments` 数的是**字面量里的花括号**

```pascal
if CurLine[col] = '{' then          // Source/Editor.pas:2986
```

这个 `{` 开启了一段**永不结束**的注释，其后每一行都被静默删除。
实测：**121 个 Delphi 树单元里有 10 个**的尾部对所有符号搜索不可见，
包括 `Editor.pas:3087` 的 `Printer.Title := FDocTitle`，以及 `main.pas` 的未知一段。

**吞掉一行 = 让一个符号看起来"未被使用"**，而"未被使用"正是唯一能授权删掉工作的分类。
这条缺陷**污染了两列**，因为消费端扫描是两份证据共用的。

### 23.4 修正后的分类，以及被它推翻的结论

| 分类 | §22（源码列） | 本节（编译器列） |
|---|---:|---:|
| 1. SHIM CANDIDATE | 1 | **6** |
| 3. NOT SAFELY SHIM-ABLE | 19 | **10** |
| 4. QUESTIONABLE | 1 | **3** |
| 5. INDETERMINATE | 2 | **3** |

**两个 §22 的结论被推翻：**

1. **`Winapi.Messages` 不是 shim 候选**——它需要 **2 个 const**（`WM_THEMECHANGED`、
   `WM_UPDATEUISTATE`），而 §22 说它是唯一候选。§22.6 第 6 条**关闭**：候选归零。
2. **§22 的"22 个里只有 1 个能 shim"作废**，因为那个 1 是 `nonwin32` 空壳的产物。

**§20 的测量（37 → 2 / 22 / 1 / 0 / 12）不受影响**：它描述的是**解析状态**，
而本节推翻的是"解析状态 = 符号面"这个假设。

### 23.5 两个 `INDETERMINATE`：**一个是解开了，另一个不解开**

- `System.SysUtils` → **3. NOT SAFELY SHIM-ABLE**（需要 2 const + 30 routine）。已定。
- `System.WideStrUtils` → 仍是 **INDETERMINATE**，而且**理由更窄了**：不是"符号面读不出来"，
  而是"`widestrutils.ppu` 只有 **22** 个公开符号，低于 25 的地板"。
  这一次是**编译器的记录**这么说的，所以它是一个**测量结论**，不是提取失败。

> 换句话说：**indeterminate 的成因分两种**，一种是"我的提取器坏了"，一种是真的小。
> 分开它们靠的是换一个不会坏的证据源，而不是更用力地猜。

### 23.6 第 4 类带着一条**常设警告**，因为它比看上去危险

`Vcl.Themes` / `Vcl.ImgList` / `System.Variants` 现在落在第 4 类
（"这个尾部单元里没有符号被引用，那条 `uses` 本身不足以立项"）。
这句话是关于**尾部单元的符号面**的，**不是**关于 Delphi 那个单元的——
本仓库枚举不出后者的符号面（vendored 树里只有 SynEdit 和 SVGIcon，没有 VCL 本体）。

所以"尾部单元没声明"与"这一行 `uses` 是历史残留"在机械上**无法区分**。
四个名字都**手工核对过消费端**：

| 名字 | 消费端 | 核对结果 |
|---|---|---|
| `Vcl.Themes` | 9 个单元 | `TThemeName` 是 `Theme.Manager.pas:16` **本地**声明的；`TStyleManager` 来自 `Vcl.Styles` |
| `Vcl.ImgList` | `EnviroFrm.pas` | 该文件引用 `TVirtualImage`，**不**引用 `TImageList` |
| `System.Variants` | 2 个单元 | 无引用 |
| `System.Math` | `main.pas` | 120 个符号，引用 0（§22 已记录，仍成立） |

### 23.7 本节自己抓到的六个缺陷（全部在被推翻的方向上）

1. **我第一版把一个诊断贴错了标签。** 那一节叫"读错 `.ppu` 的样子"，
   然后塞满了 `Create` / `Destroy` / `FItems` / `dwFlags`——真实成因是类成员。
   **一个朝着错误成因喊的诊断比没有诊断更糟**：它教会读者这一节是噪声。
   改法不是改措辞，是**用编译器自己的嵌套去分类**（`-VD` 把嵌套定义缩进，
   类成员另带 `Class : ... DefId n`），于是这一节从指控变成测量。
2. **第一轮报 177 个"无法解释"。** 因为把列 0 锚定的正则 `-VS` 用到了 `-VD` 上，
   而后者**每一行都缩进**。**177 这个数本身就是线索**：22 个单元里 177 个无法解释的
   分歧不是发现，是坏掉的扫描。
3. **剩下的 3 个（`X` / `Y` / `IsEmpty`）单独查了**，因为直接归入"良性"太便宜。
   `types.pp:87` 是 `TPoint = Windows.TPoint`——一个**别名**，所以字段 `X`/`Y`
   属于 `types` **不拥有**的那个 record。编译器两处都没记，所以它们不是单元符号。
4. **自测当场抓到棘轮的洞：基线文件不存在时 `--ratchet` 直接通过**（第一版顺手建了基线并
   `return 0`）。这比 §21.4 的"无内容的额度"高一层：那里是额度无人兑现，
   这里是**整个比较**无人兑现。已改为缺基线即失败，且只有 `--write-baseline` 能建。
5. **两次键名笔误**（`refuses` / `refutes`、`explain` / `explained`），
   两次都是 `KeyError` 而不是**静默的错误答案**——这算是运气。
6. **"复用仓库里已有的正确实现"被实测否决。** 最顺的下一步是把 `strip_comments`
   改成委托给 `comment_bleed.strip_lines`（`f3_compile_cost.py` 就是这么写的，
   而且注释里明写"不要成为第二条实现"）。实测**更差**：判定从 3/2 变成 **3/16**
   INDETERMINATE，因为它的字符串状态跨行延续，而喂进去的正是 FPC 的按平台变体。

> 所以真正的教训不是"复用共享实现"，而是 **"别再手写这个"**。
> 源码列有**三个实测缺陷**且都在危险方向上，它不值得修，值得**替换**——
> 它作为对照列保留下来，好让"为什么换"的比较可复现。

### 23.8 门禁与状态

- `tools/f3_ppu_surface.py --self-test`：**9 项**，其中 3 项专门证明棘轮会失败
  （无基线、写入后自洽、新增一条被反驳的授权）。
- `--ratchet`：`tools/f3_ppu_surface_baseline.json` 冻结三个数
  （矛盾 0 / 被反驳授权 1（`Winapi.Messages`）/ 漏读 43）+ 22×2 个分类；
  **增加、移动都失败**，下降必须 `--write-baseline` 显式确认。
- 接入 CI（`lcl-svg-runtime`，**必须**在有工具链的 job 里：选 `.ppu` 要真的编译）。
- **没有写任何 shim，没有改 Delphi 树**（`git diff` 为空）。

### 23.9 这一节对排期的净影响

- **`main.pas` 的 12 个真工作没有变化**——本节一个单元都没解开。
- 但**"那 22 个名字怎么办"这个问题现在有了答案**，而答案比乐观和悲观都更具体：

  > **6 个可以用类型别名解决（合计 18 行别名），10 个需要各自的兼容机制，
  > 3 个的 `uses` 条目很可能是残留（已逐个核对），3 个不可判定。**

- §19.8 的建议（**先攻 `main.pas`、暂不反转 `MainUi`**）**不变**：这一节没有让任何单元
  靠近可编译，只是把一个**错误的成本估计**换成了正确的。
