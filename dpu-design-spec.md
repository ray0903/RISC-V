# Data Processing Unit (DPU) Reimplementation Design Spec

## 文档导航

1. 概述与宏观架构
2. 前端、指令队列与译码
3. 流水线与双发射
4. 整数执行、寄存器堆与FPU边界
5. Load/Store与内存接口
6. 程序流、分支解析与BTAC维护
7. 异常、睡眠、Debug与Trace
8. 重实现规则与验证计划

## 1. 概述与宏观架构

本文是 Cortex-M7 `cm7dpu` 的中文行为兼容重实现规格入口。Data Processing Unit (DPU，数据处理单元) 接收 Prefetch Unit (PFU，预取单元) 输出的 Thumb 指令，完成预译码、排队、双发射判断、整数执行、访存地址生成、分支恢复、异常与系统状态管理，并把浮点、访存和追踪事务交给相邻单元。

目标不是复制原 RTL 的门级结构，而是定义可独立实现和验证的行为规则：相同的指令顺序、发射限制、寄存器和状态更新、内存副作用、分支恢复、异常精确性以及外部握手结果。

### 1.1 宏观架构

![DPU宏观架构与主数据流](assets/dpu-system-architecture.svg)

图中蓝色实线是指令、操作数、地址、数据或结果的主数据流，灰色虚线是清除、提交、异常和程序重定向控制。`cm7dpu` 是实际DPU顶层；框内带 `cm7dpu_*` 的名称均为真实RTL模块。FPU位于 `cm7dpu` 边界之外，DPU只负责译码、整数寄存器数据交换、stall/kill同步和浮点上下文控制。

主指令流从左向右进行。`cm7pfu` 每周期最多给出两条完整Thumb指令以及长度、错误、保护和 Branch Target Address Cache (BTAC，分支目标地址缓存) 元数据。`cm7dpu_front_end` 先把指令预译码并放入 Instruction Queue (IQ，指令队列)，再生成微操作、寄存器指针、立即数、执行控制和访存控制。`cm7dpu_rf` 是 Register File (RF，寄存器堆)，提供整数源操作数；Forwarding/Bypass Network (forwarding/旁路网络，以下简称旁路网络) 优先使用流水线中更新的数据，避免等待已经计算但尚未写回RF的结果。

执行阶段按指令类型分流。普通整数指令进入 `cm7dpu_dp0` 或 `cm7dpu_dp1_alu`；Multiply-Accumulate (MAC，乘加)进入`cm7dpu_mac`；divide进入`cm7dpu_div`；load/store由两个 Address Generation Unit (AGU，地址生成单元) `cm7dpu_agu`计算地址，并通过load/store swizzle模块完成字节序、对齐和符号扩展。`cm7dpu_prog_flow`与数据通路并行维护 Program Counter (PC，程序计数器)、条件执行、分支预测状态、异常和睡眠状态。结果只有在 Write (Wr，写回/提交级) 未被kill或quash时才能更新寄存器、状态标志或外部事务。

控制流的方向与主数据流相反。分支预测错误、异常、重试、调试进入或异常返回会由 `cm7dpu_prog_flow` 产生正确PC和 `force`，要求PFU停止旧路径并从新地址取指；同时按指令年龄产生每级 kill/quash。DPU不会因普通重定向清除存储器或cache内容，只使错误路径的有效状态和副作用失效。

### 1.2 章节结构

| 章节 | 重实现问题 |
| --- | --- |
| 第2章：前端、指令队列与译码 | 指令来自哪里，如何预译码、进入IQ、形成双槽控制和控制微码。 |
| 第3章：流水线与双发射 | De/Iss/Ex1/Ex2/Wr/Ret各级做什么，何时双发射，stall、kill、quash、replay怎样传播。 |
| 第4章：整数执行、寄存器堆与FPU边界 | 寄存器堆、旁路、DP0/DP1、MAC、DIV、Negative, Zero, Carry and Overflow flags (NZCV，负/零/进位/溢出标志)和FPU协作。 |
| 第5章：Load/Store与内存接口 | AGU、推测性读取、目标CS纠错、LSU、MPU、PPB、对齐、字节序、多寄存器传输、barrier和exclusive。 |
| 第6章：程序流、分支解析与BTAC维护 | PC、条件判断、Iss/Ex2/Wr分支解析、force、BTAC分配、更新和失效。 |
| 第7章：异常、睡眠、Debug与Trace | 异常入栈/返回、Lazy Floating-Point Context Save (lazy FP，浮点上下文延迟保存)、睡眠、lockup、debug、ETM和DWT。 |
| 第8章：重实现规则与验证计划 | 模块接口、优先级、reset、不可恢复细节、实现步骤和验证矩阵。 |

### 1.3 真实模块组成

| 实际模块 | 主要职责 |
| --- | --- |
| `cm7dpu` | DPU顶层；流水寄存器、旁路与interlock、访存控制、PSR/CONTROL/priority状态、写回仲裁及所有外部接口。 |
| `cm7dpu_front_end` | De源仲裁、异常/睡眠控制微码注入、AHBD代理、预译码、IQ、最终译码和Iss候选输出。 |
| `cm7dpu_predec` | 第一阶段译码，提取时间关键的寄存器读写字段、基本uOP和紧凑控制。 |
| `cm7dpu_iq` | 双head、双skid的四项顺序队列；支持每周期推入/消费两项和slot1重放。 |
| `cm7dpu_dec` | 第二阶段译码；slot0使用完整decoder，slot1使用精简decoder；产生立即数、分支、访存、ALU、MAC、DIV和FPU控制。 |
| `cm7dpu_rf` | 整数寄存器堆，四个Iss A/B读口、两个Ex2 C读口、四个写口以及Link Register (LR，链接寄存器/R14)旁路读口。 |
| `cm7dpu_dp0` | 功能完整的主整数数据通路，含移位、算术、逻辑、位操作、饱和、SIMD和标志生成。 |
| `cm7dpu_dp1_alu` | 第二发射槽的精简ALU，不包含完整shift和SIMD资源。 |
| `cm7dpu_agu` ×2 | 两个地址生成单元，计算有效地址、base writeback值和加法标志。 |
| `cm7dpu_mac` | 乘法、乘加、长乘和字节绝对差累加；输出最多64-bit结果与N/Z/Q标志。 |
| `cm7dpu_div` | radix-4、每迭代产生2-bit商的整数除法器。 |
| `cm7dpu_swizzle_load` ×2 | 从LSU/PPB返回数据中选择目标byte/halfword/word，处理端序、符号扩展和旁路格式。 |
| `cm7dpu_swizzle_store` | 在Ret根据地址、大小和端序生成64-bit store data布局。 |
| `cm7dpu_prog_flow` | PC与分支预测流水线、BTAC维护、异常/返回、sleep/halt、同步错误、lockup及全流水清除。 |
| `cm7dpu_etm_intf` | 把退休指令、访存、异常和取消转换为 Embedded Trace Macrocell (ETM，嵌入式追踪宏单元) 与 Data Watchpoint and Trace (DWT，数据观察点与追踪) 接口。 |

`cm7dpu_dp0`内部还真实实例化 `cm7dpu_alu_rbit`、`cm7dpu_alu_sat_dbl`、`cm7dpu_alu_shift`、`cm7dpu_alu_extract`、`cm7dpu_alu_maskgen`、`cm7dpu_alu_au`、`cm7dpu_alu_lu`、`cm7dpu_alu_masksel`、`cm7dpu_alu_clz`、`cm7dpu_alu_gen_sat`和`cm7dpu_alu_simd_sat`。这些是DP0的实现细节，不是独立的顶层流水级。

### 1.4 术语和流水级

| 术语 | 含义 |
| --- | --- |
| Decode (De，预译码级) | 选择PFU、控制微码或AHBD指令，执行第一阶段译码并写入IQ。 |
| Issue (Iss，发射级) | 对IQ队首做完整译码，读取源寄存器，检查相关和执行资源，决定发射零、一或两条。 |
| Execute 1 (Ex1，执行一级) | 选择旁路操作数，计算load/store地址，做移位/格式预处理，启动除法和多拍传输。 |
| Execute 2 (Ex2，执行二级) | 完成主ALU、第二ALU和分支目标计算，接收MPU属性，形成待写回结果。 |
| Write (Wr，写回/提交级) | 接收load、MAC、DIV和FPU结果，解析晚分支与异常，更新整数寄存器、NZCV和系统状态。 |
| Retire (Ret，退休观察级) | 保存已提交的PC/模式/IT状态，向store和trace提供按程序顺序的最终数据。 |
| slot0 / slot1 | 同一个cycle内按程序顺序排列的两个发射位置；slot0更老、功能更完整。 |
| micro-operation (uOP，微操作) | DPU内部执行类别位图。8位依次表示shift、ALU、load、store、MAC、DIV、branch和special；一条指令可同时置多个语义位，例如load-to-PC同时是load和branch。 |
| interlock | 因源数据、目的冲突或执行资源暂不可用而阻止指令进入下一流水级。 |
| stall | 下游不能接收时保持本级valid、控制和数据，不得重复提交。 |
| kill | 取消某级中的指令，使其及更年轻指令不再产生架构副作用。 |
| quash | 对某个slot的条件失败、分支阴影或异常进行选择性失效，常用于保留同级较老slot。 |
| replay | 指令已经部分前进，但因slot1不能继续、ECC/LSU重试或特殊序列要求而回到较早位置重新执行。 |
| 生产者/使用者（producer/consumer） | 生产者是在程序顺序上位于使用者之前、将产生某个寄存器或标志新值的指令；使用者是后续需要读取该新值的指令。 |
| 旁路（forwarding/bypass） | 生产者的结果已经产生但尚未写入RF时，直接把该结果送到使用者的操作数入口。旁路只传送已经有效的真实数据，不猜测寄存器值。 |
| speculative memory read（推测性读取） | load在到达Wr并最终commit之前，先向LSU送出地址和读请求，用于隐藏访存延迟。若该指令后来被branch、exception、condition fail或kill取消，返回数据不得写RF或形成错误路径架构副作用。 |
| Chip Select (CS，目标片选) | 指示该访存应进入ITCM、DTCM、AHBP、普通cache/外部memory或PPB中哪条目标路径。DPU可先预测CS，再用AGU完整地址纠正。 |
| commit（提交） | 指令已成为当前可提交的正确路径指令，且条件通过、无kill/quash和优先级更高的fault；只有此时才能产生架构寄存器或memory副作用。 |
| Read After Write (RAW，写后读相关) | 后序指令要读取前序指令将要写入的新值；新值尚未到合法旁路点时必须interlock。 |
| Write After Write (WAW，写后写相关) | 两条按顺序写同一架构目的；硬件必须保证程序顺序靠后的写最终可见，不能让物理写口时序颠倒程序顺序。 |
| Load/Store Multiple (LSM，多寄存器装载/存储) | 一条LDM/STM或浮点multiple指令传输多个寄存器，DPU内部迭代成多个memory beat。 |
| Load/Store Doubleword (LSD，双字装载/存储内部类别) | 一条LDRD/STRD或对应浮点操作传输两个word，并占用成对数据/写回位置。 |
| Table Branch Byte/Halfword (TBB/TBH，字节/半字表分支) | 从table读取8-bit或16-bit偏移，再把偏移用于PC重定向的复合指令。 |
| Auxiliary Control Register (ACTLR，辅助控制寄存器) | 实现相关的性能和勘误控制寄存器；本DPU用若干位关闭全部或特定类别的双发射。 |
| Coprocessor Access Control Register (CPACR，协处理器访问控制寄存器) | 控制软件是否可以访问FPU等协处理器；不允许时FPU指令走NOCP/UNDEFINED路径。 |
| single-step | 调试器要求CPU每次只执行并观察一条真实指令的模式，因此DPU强制单发射。 |
| UNDEFINED / UNPREDICTABLE | 前者表示编码或功能不受支持并进入未定义指令异常路径；后者表示软件使用了架构不保证结果的组合，DPU通常保守单发射以形成确定边界。 |
| NZCV | APSR中的N、Z、C、V四个条件标志，分别描述结果符号、是否为零、无符号进位/无借位和有符号溢出。 |
| Program Status Register组合视图 (xPSR，程序状态寄存器组合视图) | 把Application Program Status Register (APSR，应用程序状态寄存器)、Interrupt Program Status Register (IPSR，中断程序状态寄存器)和Execution Program Status Register (EPSR，执行程序状态寄存器)作为一个32-bit架构状态保存或恢复；`x`表示这三种PSR的组合视图。 |
| LR | 普通函数调用时保存返回地址；异常handler中保存特殊的EXC_RETURN值，用于描述异常返回方式。 |
| Stack Pointer (SP，栈指针/R13) | 指向当前栈顶。Cortex-M提供Main Stack Pointer (MSP，主栈指针)与Process Stack Pointer (PSP，进程栈指针)，当前执行模式决定实际使用哪一个。 |
| architectural state | 软件可观察的寄存器、xPSR、CONTROL、mask/priority、memory side effect和异常状态。 |

### 1.5 模块边界

DPU负责决定数据访问地址和访问语义，但不实现D-cache、TCM存储阵列或MPU region matching。它把地址并行发送给 Load Store Unit (LSU，装载存储单元) 和 Memory Protection Unit (MPU，内存保护单元)，随后使用返回的属性、abort和load data决定提交。Private Peripheral Bus (PPB，私有外设总线) 地址由DPU识别并走独立握手。

DPU负责浮点指令的识别、整数寄存器交换、异常上下文和流水同步，但浮点算术在外部 Floating-Point Unit (FPU，浮点单元)完成。DPU负责向PFU报告正确PC和BTAC维护信息，但不保存BTAC表。DPU负责向Nested Vectored Interrupt Controller (NVIC，嵌套向量中断控制器)报告异常进入、退出和mask变化，但中断优先级选择由NVIC完成。Advanced High-performance Bus Debug (AHBD，AHB调试访问代理)通过DPU访存通路执行调试内存访问。

### 1.6 源码完整性限制

本代码包中 `cm7dpu_rf.v`、`cm7dpu_alu_shift.v`、`cm7dpu_alu_simd_sat.v`、`cm7dpu_dec_full_t16_post.v`和`cm7dpu_dec_fpu_full_t32_post.v`为零字节。顶层及相邻模块仍然实例化它们，因此接口、时序位置和外围行为可以恢复，但以下细节不能从当前源码逐项证明：

1. 寄存器堆的具体阵列复制、写优先级门级结构和读写同址物理实现。
2. 全部shift边界值和SIMD饱和的内部组合逻辑结构。
3. slot0全部16-bit Thumb和完整FPU 32-bit指令的逐opcode decoder真值表。

重实现必须依据Armv7-M指令语义补齐这些功能，并用本文定义的端口、流水级、interlock和提交规则接入。不能把零字节文件解释为“该功能不存在”。

## 2. 前端、指令队列与译码

本章描述DPU前端。PFU提供普通指令，Advanced High-performance Bus Debug (AHBD，AHB调试访问代理)提供调试访存请求。

### 2.1 前端数据流

![DPU前端数据流](assets/dpu-front-end-flow.svg)

`cm7dpu_front_end`把三类指令源统一成同一种IQ entry。正常运行时两个slot都来自PFU；异常、返回、sleep或halt序列只占slot0；AHBD调试内存代理也只占slot0。源仲裁优先级为AHBD、控制微码、PFU，同一cycle不能把特殊项和普通PFU指令混合写入IQ。这样IQ中的程序顺序和“是否可被异常打断”的属性始终明确。

每个entry不仅保存指令位，还保存Thumb-16/Thumb-32长度、预译码结果、错误、调试保护、BTAC hit位置和微码状态。`cm7dpu_predec`位于De，提前计算Iss关键路径上的寄存器指针和粗粒度操作类型；`cm7dpu_dec`位于Iss，补齐立即数、ALU/MAC/DIV/AGU控制、条件码和FPU control bus。

### 2.2 De源仲裁规则

| 条件 | slot0来源 | slot1来源 | PFU pop |
| --- | --- | --- | --- |
| AHBD请求获准注入 | 合成load/store调试指令 | 无效 | 0 |
| 控制状态产生有效微码，`ctl_ival_de=1` | 异常/返回/lazy/sleep内部操作 | 无效 | 0 |
| 控制状态处于等待、halt或special驻留，`ctl_ival_de=0` | 无效 | 无效 | 0 |
| 正常run | PFU slot0 | PFU slot1 | 取决于IQ空间和BTAC限制 |
| lazy push刚被请求 | 控制序列获得优先级 | 无效 | 0 |
| BTAC side queue满 | 对应hit的slot停止pop | 可独立接受不受影响的更老slot | 0或1 |

PFU提供两条指令不代表DPU必须同时接收。De先询问`cm7dpu_iq.can_pop_de_o`，再叠加BTAC side queue约束。一个cycle最多接受一个BTAC hit，因为前端只有一个BTAC元数据写入口，队列最多保存两个未发射hit。

错误和BTAC命中同时出现时，非法BTAC命中检查优先。原因是命中可能落在32-bit指令首半字或非分支上，此时原本附着的错误也可能属于错误取指关联，必须先refetch而不是直接提交错误。

### 2.3 Instruction Queue

![双head双skid IQ](assets/dpu-iq-structure.svg)

IQ由两个head寄存器和两个skid寄存器组成，总容量四项。head0永远表示最老待发射项，head1表示下一项；skid保存已经从De接收但暂时不能进入head的后备项。`skid_f`记录两个skid entry的时间先后，避免物理编号被误当成程序顺序。四个位置保存相同格式的压缩预译码entry，不是四份完整原始指令。

图分成三层阅读。顶部把四个物理寄存器还原成逻辑FIFO顺序：`head0`是最老entry，`head1`是第二老entry，两个skid依次保存第三和第四项；Issue从左侧消费，De从右侧加入新项。中部说明head位置固定，而`skid0_q`和`skid1_q`谁更老由`skid_f`决定。底部用A、B、C、D展示stall期间C、D进入skid，以及只发射A后B、C、D同时保持顺序前移。图中的左移箭头表示逻辑年龄前移，不表示四个entry每拍都无条件改写。

#### 2.3.1 IQ entry保存的内容

默认`uOP_W=8`时，每个IQ entry宽68 bit。`head0_q`、`head1_q`、`skid0_q`和`skid1_q`的数据格式完全相同；entry来源可以是普通PFU指令、控制微码或AHBD伪指令。顶层拼接关系为：

```text
IQ entry[67:0] = {
    port_pre_dec[61:0],
    protection,
    error_present,
    instruction_status[3:0]
}
```

![DPU IQ entry数据格式](assets/dpu-iq-entry-format.svg)

图的顶部给出68-bit布局。最大的49-bit区域已经是`cm7dpu_predec`产生的控制摘要，后面只保留T32长度位和12-bit压缩编码字段；因此IQ不是保存完整16/32-bit原始instruction的instruction memory。图中部把49-bit控制摘要按功能分组，图下部说明同一个`istat`字段如何根据普通PFU、控制微码或AHBD来源解释。最下方红框列出的PC、详细BTAC信息和error code等内容由独立状态保存，不能假定它们藏在IQ entry中。

68-bit顶层字段如下：

| Bit | 宽度 | 字段 | 设计含义 |
| --- | ---: | --- | --- |
| `[67:19]` | 49 | 预译码控制摘要 | uOP、寄存器依赖、执行语义、合法性和可选FPU/misc字段；直接服务Iss关键路径。 |
| `[18]` | 1 | `inst_s` / T32 | 1表示32-bit Thumb形式，0表示16-bit Thumb形式；内部微码和AHBD伪指令按生成的内部编码设置。 |
| `[17:6]` | 12 | `field[11:0]` | `cm7dpu_predec`按指令类别从原编码不同位置抽取并重新排列的字段，供Iss第二阶段decoder重建立即数、寄存器和控制。它不是固定的`instr[11:0]`。 |
| `[5]` | 1 | `protection` | 普通PFU指令附带的debug/protection属性；特殊内部项中该物理位仍存在，但只在对应控制路径认为有意义时使用。 |
| `[4]` | 1 | `error_present` | 当前普通PFU entry关联取指错误；控制微码和AHBD项生成时被run条件屏蔽。 |
| `[3:0]` | 4 | `istat` | 来源和顺序属性复用字段；普通项保存BTAC raw hit位置，微码保存first/last/kill-mask，AHBD标记debug来源。 |

49-bit预译码控制摘要不是未经解释的位块，其内部语义可按以下六组重实现：

| 分组 | 宽度 | 保存内容 | Iss用途 |
| --- | ---: | --- | --- |
| 合法性与slot提示 | 3 | 两类undefined摘要和`inst01`提示 | 选择full/small decoder合法性，识别需要特殊slot关系的指令。 |
| uOP类别 | 8 | shift、ALU、load、store、MAC、DIV、branch、special位图 | 快速判断执行资源、分支和interlock类别。 |
| 寄存器依赖摘要 | 17 | A/B/C/D读使能、A/B读指针、写使能、预译码目的指针 | Iss读RF并提前检测RAW/WAW和读写端口冲突。 |
| 执行语义摘要 | 5 | can-return、LSM/flag-setting复用位、IT、flags、use-AGU | 选择程序流、条件执行和地址生成路径。 |
| misc immediate | 5 | `use_misc_imm`和4-bit压缩值 | long immediate、LDC/STC等少数类型的补充编码；无效时可clock-gate。 |
| FPU摘要 | 11 | FP类型、单双精度、VMOV变体、输入/结果宽度和data选择 | Iss阶段完成FPU译码与资源限制；非FPU项可clock-gate。 |

`field[11:0]`必须按“压缩后译码字段”理解。对于不同T16/T32指令，predecoder由`field_sel`从原指令的不同bit位置提取字段，例如立即数片段、寄存器片段、IT字段或分支相关片段。第二阶段`cm7dpu_dec`接收`uOP + T32 + field`等预译码信息完成最终控制生成，所以不能把该12-bit字段直接解释成原指令低12位。

`istat[3:0]`是复用字段：

| Entry来源 | `istat`解释 |
| --- | --- |
| 普通PFU指令 | `[3:2]=00`，`[1:0]`保存与该指令关联的原始BTAC hit位置。 |
| 控制微码 | `[3]=0`，`[2:0]`依次表示first、last和mask-kill，使多个内部操作形成一个受控序列。 |
| AHBD伪指令 | `[3]=1`标记AHBD来源；其余位保存序列last和从当前微码环境继承的kill-mask属性。 |

以下状态不在这个68-bit entry中，必须由独立结构与IQ entry保持同步：

| 不在entry中的内容 | 实际保存位置或处理方式 |
| --- | --- |
| 完整16/32-bit原始指令 | De预译码后不随IQ保存；Iss使用压缩字段和预译码摘要。 |
| 指令PC | 由`cm7dpu_prog_flow`的PC/程序流上下文维护，不是IQ data字段。 |
| BTAC taken、offset和index | 保存在前端独立的两项BTAC side queue；IQ只携带raw hit位置用于关联。 |
| 详细PFU error code | `error_present`在IQ中，具体`pfu_dpu_err_code_i`在错误项pop时捕获到独立`err_code_iss`寄存器。 |
| Entry valid | 分别保存在`head_v[1:0]`和`skid_v[1:0]`，flush主要清这些valid，不要求清空data位。 |
| 两个skid的年龄顺序 | 由`skid_f`维护。 |
| slot1 replay副本 | 由独立`i1_ex1`寄存器保存，不占普通四项IQ entry。 |

因此，“指令、错误、保护和预测信息原子移动”不表示所有信息都打包在同一个向量里，而是要求IQ entry、BTAC side queue、error code寄存器和程序流PC上下文在push、pop、stall、flush和replay时始终指向同一条逻辑指令，不能发生跨entry错配。

功能级重实现可以选择在四项FIFO中直接保存完整原始instruction，再在Issue重新译码，但必须产生与上述压缩entry相同的依赖、执行、错误和来源语义。cycle-accurate重实现还应保持De预译码、Iss后译码的阶段边界，以及FPU/misc字段按valid条件clock-gate的行为。

#### 2.3.2 基本动作

| 动作 | 结果 |
| --- | --- |
| push 0项 | 所有entry保持，除非同时发生Iss消费。 |
| push 1项 | 优先填空head；head无空间时填最老可用skid。 |
| push 2项 | 两项保持slot0早于slot1的顺序，分别进入可用head/skid。 |
| consume slot0 | head0移除；原head1前移到head0；skid按顺序补空位。 |
| consume slot0+slot1 | 两个head同时移除；skid最多补入两个head。 |
| stall Iss | head输出和valid保持；De仍可填尚未占用的skid。 |
| flush | 正常head/skid valid清零；旧路径entry不得再次输出。 |
| replay slot1 | 将上一cycle未能完成的slot1作为新的最老slot0重新送Iss，保持原PC和预测上下文。 |

IQ的`can_pop_de_o`是容量保证，不是发射保证。De写入只说明entry被可靠缓存；最终能否同时执行由Iss interlock决定。

#### 2.3.3 为什么它仍然是深度4 FIFO

从功能模型看，`cm7dpu_iq`就是一个深度为4、每cycle最多push两项并最多pop两项的有序First In First Out (FIFO，先进先出队列)。head和skid不是两种不同格式的entry，也不是两个串联队列；它们只是同一FIFO的物理位置划分：

| FIFO逻辑位置 | 物理保存位置 | 是否直接送Issue |
| --- | --- | --- |
| entry 0，最老 | `head0_q` | 是，作为Iss slot0。 |
| entry 1，第二老 | `head1_q` | 是，作为Iss slot1。 |
| entry 2 | `skid_f=0`时为`skid0_q`，`skid_f=1`时为`skid1_q` | 否，等待补入head。 |
| entry 3，最新 | 使用另一个skid寄存器 | 否，等待更老项先前移。 |

逻辑顺序必须始终满足：

```text
oldest -> head0 -> head1 -> older skid -> newer skid -> newest
```

其中`head1` valid必然意味着`head0` valid。两个skid物理寄存器会被交替复用，所以不能固定认为`skid0`永远比`skid1`老。`skid_f=0`表示`skid0`较老，`skid_f=1`表示`skid1`较老；head出现空位时必须根据该位选择正确的skid前移。

之所以采用dual-head、dual-skid而不是普通四项RAM加read pointer，主要是为了满足DPU时序：

1. Issue每cycle需要同时看到最老两项，固定的`head0/head1`可直接连接两个译码slot，不需要双读RAM或大范围队首mux。
2. Issue发生短暂stall时，head必须稳定；两个skid仍可吸收De已经送来的最多两项，减少立即反压PFU的概率。
3. 单发射时，原`head1`可直接前移到`head0`，最老skid同时补入`head1`；双发射时，两个skid最多同时补入两个head。
4. valid和小范围选择器只在需要移动的寄存器上更新，便于时序和clock-gating优化。

`can_pop_de_o`表达当前IQ还能从De可靠接收多少项。由于skid只在head无法容纳更多年轻项时才保持valid，它可以直接由两个skid valid计算：

| `skid_v`状态 | 当前逻辑容量状态 | `can_pop_de_o` | De本拍最多接收 |
| --- | --- | --- | ---: |
| `00` | FIFO最多已有2项，两个后备位置都空 | `11` | 2项 |
| `01`或`10` | FIFO已有3项，只剩一个后备位置 | `01` | 1项 |
| `11` | FIFO四项已满 | `00` | 0项 |

这里的`can_pop`只表示容量，不保证接收的指令本拍就能发射。它也不把时序较晚的Issue结果乐观地计入空位；push和pop真正同时发生时，内部`gen_ctl`根据0、1、2项issue情况选择对应的数据移动方案，并保持FIFO顺序。

图中的A、B、C、D例子可以写成逻辑队列变化：

```text
C0 push A,B：      [A, B]
C1 Iss stall并push C,D：[A, B, C, D]
C2 pop A：         [B, C, D]
C3 pop B,C：       [D]
```

skid也不是slot1 replay buffer。slot1需要replay时，RTL使用独立的`i1_ex1`寄存器保存已发射slot1上下文，并通过`replay_ctl_ex1_i`重新把它作为slot0输出；不能用普通skid entry替代这条路径。

功能级重实现可以直接使用四项数组、read/write pointer和occupancy count，只要保持相同的有序双push/双pop行为。若要求cycle-accurate兼容，还必须复现`can_pop_de_o`、stall下head稳定、flush清valid、同cycle数据补位以及slot1 replay的具体时序。

### 2.4 两阶段译码

#### 2.4.1 `cm7dpu_predec`

预译码对两个slot都执行，输出紧凑字段供IQ存储。其职责是：

1. 区分16-bit与32-bit Thumb编码空间。
2. 提取候选A/B/C源寄存器和最多四个目的寄存器字段。
3. 产生8-bit uOP类别位图以及是否需要第二阶段完整译码的选择字段。
4. 标记分支、load/store、MAC、FPU、长立即数和特殊系统指令类别。
5. 保留后译码重建立即数和condition所需的原指令字段。

预译码输出不是最终执行许可。UNDEFINED、UNPREDICTABLE、coprocessor不可用、寄存器组合非法和slot1能力限制在Iss进一步判定。

#### 2.4.2 `cm7dpu_dec`

slot0使用full decoder，可产生完整DP0、MAC、DIV、LSM/LSD、system和FPU操作；slot1使用small decoder，只允许第二执行通路支持的子集。译码器输出至少包括：

| 类别 | 输出语义 |
| --- | --- |
| uOP | 该slot使用shift、ALU、load、store、MAC、DIV、branch或special中的哪些资源。 |
| RF pointers | A/B/C源寄存器、最多四个目的寄存器以及每个目的属于哪个slot。 |
| immediate | 数据处理立即数、shift amount、load/store offset、branch offset和CBZ offset。 |
| execution control | DP0 Ex1/Ex2控制、DP1控制、MAC command、signed divide和AGU pre/post/writeback。 |
| program flow | direct/indirect branch、link、condition、IT、可改变T-bit、可exception-return。 |
| memory | load/store大小、signed、exclusive、unprivileged、multiple/double、barrier和prefetch。 |
| FPU | 指令类型、单双精度、读写寄存器指针、wide、VMOV/VMRS和load/store multiple属性。 |

uOP是可组合位图而非互斥枚举。比如load到PC需要同时设置load和branch；地址生成的ALU操作可能与load/store位同时存在；special位表示需要程序流或系统状态参与，不等于独立执行单元。

### 2.5 微码概念、来源与异常协作

#### 2.5.1 异常上下文基础：lazy、xPSR、LR与SP

异常entry和return微码的核心工作是保存或恢复“被打断程序继续执行所需的上下文”。其中，SP决定上下文保存到哪里，LR区分普通函数返回与异常返回，xPSR保存条件标志和异常执行状态，lazy则决定浮点上下文何时真正写入memory。四者的关系如下图。

![异常上下文中的SP、LR、xPSR与lazy浮点保存](assets/dpu-exception-context-primer.svg)

图的左侧表示SP与基本整数frame。Cortex-M把R13解释为SP，但内部有MSP和PSP两个实体：Handler mode使用MSP；Thread mode按照`CONTROL.SPSEL`选择MSP或PSP。栈向低地址增长，因此异常entry先向低地址调整当前SP，再从新SP开始保存8个word。异常return则从当前SP读取frame，并把SP恢复到entry之前的位置。

基本整数frame共8个32-bit word，即32 bytes。从frame基地址，也就是异常入栈后的SP开始，地址由低到高依次是R0、R1、R2、R3、R12、被打断程序原来的LR、Return PC和xPSR。Return PC是恢复取指的位置，xPSR是恢复执行状态的独立字段，两者不能混为一个返回地址。若启用了8-byte stack alignment且entry前SP未对齐，硬件还会在frame的高地址侧加入一个padding word，并通过stacked xPSR中的对齐标记保证return时正确跳过它。

**LR是什么。** LR是R14。普通`BL`或`BLX`函数调用把返回信息写入LR，函数通常通过`BX LR`返回。异常entry时，旧LR已经作为基本frame的一部分保存到stack；进入handler后，硬件写入LR的不是普通代码地址，而是一个EXC_RETURN编码。EXC_RETURN描述return后进入Thread还是Handler mode、使用MSP还是PSP，以及stack中是基本frame还是扩展浮点frame。handler执行`BX LR`时，程序流单元识别该编码并启动异常return微码，而不是把它当成普通branch target。

**多个函数嵌套时LR如何保存。** Cortex-M只有一个物理LR。每执行一次`BL`或`BLX`，新调用的返回信息都会覆盖当前LR。因此，一个还要调用其他函数的非叶函数必须在下一次调用之前保存自己的LR，通常保存到当前函数的stack frame；不再调用其他函数的叶函数如果没有其他保存需求，则可以直接通过`BX LR`返回。

![嵌套函数调用中的LR与stack frame](assets/dpu-lr-nested-call-stack.svg)

图的上半部分按照`main → A → B → C`展示LR的覆盖过程。`main`调用A后，LR表示“A执行结束后返回main”的位置；A先保存该值，再调用B，于是物理LR改为“B返回A”；B用同样方式保存自己的LR后调用C。C是叶函数，没有执行新的`BL`，因此可以直接使用当前LR返回B。随后B和A分别从自己的frame恢复早先保存的返回信息，按相反顺序返回。

图的下半部分说明两个已保存LR之间为什么可能存在普通寄存器值和其他数据。一个软件函数的stack frame可能包含：

| Frame内容 | 用途 |
| --- | --- |
| 保存的LR | 保留该函数返回调用者所需的地址和Thumb状态信息。 |
| callee-saved普通寄存器 | 函数使用R4-R11等按调用规则必须保持的寄存器时，先保存旧值，返回前恢复。 |
| 局部变量和spill slot | 为无法全部保存在寄存器中的局部值、编译器临时值或寄存器溢出值分配空间。 |
| 栈上传递的参数 | 寄存器参数不足，或调用规则要求在stack传递时保存参数。 |
| frame pointer和alignment padding | 帮助定位frame，或满足4-byte/8-byte等栈对齐要求。 |

因此，A保存的LR和B保存的LR通常不会紧挨在一起；A frame中的普通寄存器、局部数据，以及B frame中的其他字段都可能位于两者之间。具体顺序由Application Binary Interface (ABI，应用二进制接口)、编译器优化和函数实际需求决定，不能假定所有函数都使用完全相同的`PUSH`顺序。

函数返回时，CPU不会在stack中搜索下一个LR。编译器已经知道当前frame的大小和每个保存值相对SP或frame pointer的位置，因此会生成确定的SP调整与恢复指令。例如，`ADD SP, #local_size`先释放局部变量空间，`POP {R4,R6,PC}`再恢复普通寄存器，并把原先保存在返回地址槽中的值直接装入PC完成返回。编译器也可以使用`STR/LDR`单独保存和恢复LR，或者暂存在其他寄存器中；这些实现形式不同，但都必须确保下一次`BL`覆盖LR之前，旧返回信息已经被可靠保存。

必须区分软件函数frame和硬件异常frame：软件函数frame由ABI、编译器与函数需求决定；异常entry由硬件和DPU微码建立固定的基本整数frame，其中旧LR只是R0-R3、R12、Return PC和xPSR旁边的一个固定字段。异常return也不是按普通函数frame布局执行，而是根据EXC_RETURN选择MSP/PSP和frame类型。

**xPSR是什么。** xPSR不是另一个独立的物理状态寄存器，而是APSR、IPSR和EPSR的组合架构视图：

| 组成部分 | 主要内容 | 异常return为何需要恢复 |
| --- | --- | --- |
| APSR | N、Z、C、V、Q等算术条件标志，以及相关扩展状态。 | 保证被打断指令流恢复后，条件执行与后续算术观察到原来的标志。 |
| IPSR | 当前异常号；Thread mode时为0。 | 确定恢复后的异常层级和执行模式。 |
| EPSR | Thumb执行状态以及IT block等执行控制状态。 | 保证从Return PC继续时使用正确的指令集和条件执行上下文。 |

异常entry保存的是“被打断时”的xPSR；进入handler后，当前IPSR会变成handler对应的异常号。异常return从stack恢复xPSR，不能用handler执行期间的新NZCV或新IPSR覆盖stacked值。

**lazy是什么。** 本文中的lazy特指Lazy Floating-Point Context Save，即“浮点上下文延迟保存”。它不是延迟整个异常入栈：基本整数frame仍在exception entry时立即写入memory；被延迟的只有S0-S15、Floating-Point Status and Control Register (FPSCR，浮点状态控制寄存器)和一个保留word组成的18-word、72-byte浮点frame。

| FP上下文状态 | Entry时的动作 | Handler第一次执行浮点指令时 |
| --- | --- | --- |
| `FPCA=0` | 只保存32-byte基本整数frame，不为浮点frame预留空间。 | 不存在属于被打断上下文的浮点frame。 |
| `FPCA=1, LSPEN=0` | 立即写入72-byte浮点frame，再写入32-byte基本整数frame。 | 浮点上下文已经保存，可直接执行。 |
| `FPCA=1, LSPEN=1` | 先为72-byte浮点frame预留stack空间并记录FPCAR，但暂不写S0-S15/FPSCR；基本整数frame仍立即写入。 | 若handler真的使用FPU，当前浮点指令先被quash，DPU执行lazy保存微码写满预留frame，随后replay该浮点指令。 |

因此，lazy的收益是：大量完全不使用FPU的handler不必在entry临界路径上产生18次word级浮点上下文写入，从而减少中断延迟和memory bandwidth。它的代价是第一次在handler中使用FPU时产生一次延迟，并要求硬件严格保持“预留空间、记录地址、取消触发指令、保存旧上下文、重放触发指令”的顺序。

重实现必须遵守以下规则：

1. SP选择、向低地址增长、frame布局和可选alignment padding必须与架构一致。
2. stacked LR、Return PC和stacked xPSR是三个不同字段；异常entry后handler可见的LR是EXC_RETURN。
3. EXC_RETURN必须由程序流单元按异常返回编码解释，不能当成普通branch地址送往PFU。
4. lazy模式只能推迟浮点frame的memory写入，不能推迟基本整数frame，也不能在预留SP空间之前让handler浮点指令修改旧浮点上下文。
5. lazy触发指令必须先quash，浮点frame完整保存且相关fault/retry处理完成后才能replay；不得让部分frame写入被误认为已完成的架构状态。

#### 2.5.2 什么是控制微码

微码（microcode）是DPU为了完成异常进入、异常返回、lazy浮点上下文保存、sleep等多步骤硬件动作，在内部按顺序生成的一组操作。它不来自instruction memory，不由PFU提供，也不属于软件程序；`cm7dpu_front_end`把这些操作编码成内部Thumb形式并送入正常DPU流水线，从而复用已有的译码器、Register File (RF，寄存器堆)、Address Generation Unit (AGU，地址生成单元)、Load Store Unit (LSU，装载存储单元)、stall和retry机制。

“控制微码”不能简单理解成一个常量数组。本实现把它拆成四个层次：

| 层次 | 代表信号或状态 | 作用 |
| --- | --- | --- |
| 微码操作命令 | `mcode_op_de_i`，例如`MC_OP_ENT`、`MC_OP_REF` | 由`cm7dpu_prog_flow`发出，选择要启动哪一种entry、return、lazy、sleep或halt序列；命令本身不是IQ指令。 |
| 微码状态机 | `ctl_st_de` | 记录序列当前走到哪一步，决定本拍是否生成内部操作和下一状态。 |
| 内部Thumb形式操作 | `ctl_inst_de`与`ctl_ival_de` | `ctl_ival_de=1`时形成一项可预译码、可写入IQ、可沿正常流水线执行的内部操作。 |
| 微码边界属性 | `ctl_istat_de`以及lazy等上下文 | 标记序列的first、last、kill-mask和frame类型，使多个内部操作在架构上表现为一个受控动作。 |

当前RTL不是从一块可编程microcode ROM顺序读取内容，而是在`ctl_st_de`的组合case中选择硬编码Thumb形式操作。Thumb编码只是复用执行硬件的内部载体；重实现真正必须复现的是保存或恢复哪些架构状态、SP如何变化、是否访问memory、fault/retry如何处理以及序列何时完成，不能只复制32-bit常量。

![DPU控制微码生成、注入与执行](assets/dpu-microcode-overview.svg)

图的上半部分从左向右展示三条De候选路径。异常和系统事件先由`cm7dpu_prog_flow`转换成微码操作命令，再由`cm7dpu_front_end`状态机逐条生成控制微码；AHBD调试请求由独立代理生成调试伪指令；PFU提供正常程序或handler的普通Thumb指令。三类候选最终进入同一个De源仲裁器，而不是在进入IQ之前拼成一条混合指令流。

图右侧表示仲裁和执行。控制微码或AHBD项被选中时只能写slot0，slot1无效且PFU不pop；正常run时才允许PFU slot0和slot1同时写入IQ。无论内部微码还是普通指令，进入IQ后都复用DPU执行流水线，但微码的PC、提交边界、killability和异常属性由其附加状态解释，不能按普通软件指令处理。

图底部是普通IRQ的主生命周期：正常PFU执行期间NVIC发出invoke后，程序流单元启动`MC_OP_ENT`，异常entry微码只占slot0；微码注入完成后进入`ST_WAIT`等待IQ排空；异常handler地址建立后，handler中的Thumb指令才重新作为普通PFU输入进入IQ。图中省略了late arrival和tail-chain分支，它们在2.5.5节单独说明。

#### 2.5.3 哪些内容属于特殊项

前端仲裁语境中的“特殊项”是所有不直接来自PFU、但需要占用DPU指令流水线的内部注入项：

| 特殊项类别 | 具体内容 | IQ行为 |
| --- | --- | --- |
| 异常entry微码 | 整数frame push、完整浮点frame保存、lazy frame建立 | 只写slot0，PFU不pop。 |
| 异常return微码 | full、partial或lazy return中的PC/xPSR读取、整数寄存器恢复、浮点frame恢复和SP调整 | 只写slot0，PFU不pop。 |
| lazy浮点保存微码 | 在lazy上下文真正需要落栈时保存浮点寄存器 | 只写slot0，完成后在`ST_LZWT`等待排空。 |
| sleep微码 | 内部WFI操作 | 只写slot0，然后等待精确退休和sleep状态机。 |
| fake entry/return微码 | entry/return失败或修正路径中的SP增加、减少或保持操作 | 只写slot0。 |
| AHBD调试伪指令 | 调试load；调试store对应的`DSB -> STR -> DSB`序列 | 属于特殊注入项但不属于控制微码，只写slot0。 |

`ST_WAIT`、`ST_LZWT`、`ST_HALT`、`ST_MCHL`和`ST_SPEC`等控制状态可能不生成内部指令；它们不是“空微码指令”，而是保持控制权、阻止PFU输入或等待已有微码离开IQ的状态。相反，PFU指令携带的fetch error、protection属性和BTAC元数据仍然属于普通PFU输入项，它们与对应指令原子写入IQ，不属于这里的非PFU特殊注入项。

De源选择必须按以下语义实现：

```text
if AHBD候选项有效且没有被微码原子区屏蔽:
    IQ.push(slot0 = AHBD伪指令, slot1 = invalid)
    PFU.pop = 0
else if ctl_st_de != ST_IDLE:
    if ctl_ival_de:
        IQ.push(slot0 = 当前控制微码, slot1 = invalid)
    else:
        IQ不写入新项
    PFU.pop = 0
else:
    IQ按容量和BTAC约束接收PFU slot0/slot1
```

这里的AHBD高优先级是有条件的。微码状态机可通过`msk_ahbd_de`阻止AHBD插入必须连续的异常frame操作之间，避免调试事务破坏原子序列。因此重实现不能只做一个固定三选一mux，还必须保留“微码可屏蔽AHBD”的边界条件。

禁止混写不只表示“同一cycle不能把微码和PFU slot1一起push”。控制序列结束后，`ST_WAIT`或`ST_LZWT`还要等待IQ清空才返回`ST_IDLE`并重新接受PFU，因此新handler指令不能提前与entry微码共存于IQ。这里等待的是“微码离开IQ”，不是“微码离开整个执行流水线”：最后一项微码已经进入Ex1之后，handler指令可以进入空出的IQ，并在更年轻的流水级跟随，但不能越过仍在Ex1/Ex2/Wr中的微码。接受异常时，异常边界之后的年轻PFU项会被flush；更老指令必须先完成或在精确边界被处理。

#### 2.5.4 异常微码具体完成什么

异常请求本身不是一条指令。Nested Vectored Interrupt Controller (NVIC，嵌套向量中断控制器)只向DPU报告待处理异常和invoke事件；DPU在精确指令边界上启动异常entry微码。一次典型entry需要完成：

1. 保存返回PC和xPSR。
2. 保存`R0-R3`、`R12`和`LR`，形成整数stack frame。
3. 根据当前SP选择和frame类型更新SP。
4. 根据FPCA/LSPEN状态选择不保存浮点frame、立即保存完整浮点frame或建立lazy浮点保存上下文。
5. 让vector fetch得到的handler地址成为后续正确PC，并阻止错误路径指令提交。

异常return执行相反方向的工作，但不同frame类型需要不同序列：

| Return类型 | 内部操作语义 |
| --- | --- |
| full return | 读取stack中的PC和xPSR，恢复整数寄存器，再恢复完整浮点frame。 |
| partial return | 读取PC/xPSR并恢复整数frame，不恢复完整浮点frame。 |
| lazy return | 恢复整数frame，并按lazy frame语义修正SP。 |
| fake return | 不执行正常memory unstack，只按失败或修正路径增加SP或保持SP。 |

内部操作虽然使用STM、LDM、浮点load/store、ADD/SUB SP或WFI等Thumb形式编码，但它们不是普通软件指令。它们不使用普通程序PC递增关系，不进入BTAC学习，不允许slot1越过，并通过first、last和kill-mask属性建立一个完整异常动作的边界。执行期间发生MPU fault、bus fault或LSU retry时，程序流单元必须按异常entry/return专用恢复规则处理，不能把已经完成的部分简单当作普通指令提交。

#### 2.5.5 普通中断何时触发微码

普通IRQ变成pending时不会立即生成微码。只有NVIC完成mask和priority判断，并在DPU允许的精确边界给出`int_invoke`后，`cm7dpu_prog_flow`才在正常`ST_IDLE`路径发出`MC_OP_ENT`。`cm7dpu_front_end`收到该命令后进入`ST_ENT0`，再根据整数、full FP或lazy FP frame选择具体entry序列。

| 场景 | 是否启动新的`MC_OP_ENT` | 设计原因 |
| --- | --- | --- |
| Thread mode正常执行时接受IRQ | 是 | 需要建立一层新的异常stack frame。 |
| Handler中接受更高优先级IRQ | 是 | 形成嵌套异常，需要再保存一层上下文。 |
| IRQ仅为pending，但被PRIMASK、BASEPRI或优先级阻止 | 否 | NVIC尚未给DPU有效invoke。 |
| 异常entry执行期间发生late arrival | 不重新执行完整push | 当前stack frame已经在建立；更高优先级异常替换待进入的handler，已有压栈继续有效。 |
| 异常return期间发生tail-chain | 不执行新的完整entry push | DPU中止或跳过unstack，复用现有stack frame直接进入下一个handler。 |
| reset vector尚未建立 | 否 | DPU没有可用于异常边界的初始PC和SP。 |

Late arrival（迟到中断）表示异常entry尚未提交时出现更高优先级异常。RTL允许新的arrival屏蔽当前待提交ISR首指令并更新异常选择，但不会为同一份被中断上下文重复压栈。Tail-chain（尾链）表示异常return尚未完成时又有异常被invoke；程序流状态机从return等待路径转到entry执行上下文，复用现有frame，省去先unstack再push的往返memory操作。

必须区分中断处理过程中的四种对象：

| 对象 | 是否为普通PFU指令 | 是否作为指令进入IQ |
| --- | --- | --- |
| NVIC的IRQ/NMI请求 | 否，是异步控制事件 | 否 |
| 异常entry/return微码 | 否，是DPU内部特殊项 | 是，只进入slot0 |
| Vector Table中的handler地址 | 否，是用于重定向PC的地址数据 | 不作为普通指令进入IQ |
| handler中的Thumb指令 | 是 | 微码排空并恢复正常run后，按普通PFU规则进入slot0/slot1 |

同步异常也遵循这个边界。例如SVC指令本身是PFU取回的普通Thumb指令；SVC退休后触发的上下文保存、vector重定向和异常entry则属于程序流控制与内部微码，不是SVC之后凭空出现的普通PFU指令。

#### 2.5.6 微码重实现规则

1. `mcode_op_de_i`是启动序列的命令，不得作为一条IQ指令执行。
2. 只有`ctl_ival_de=1`的控制状态才能push内部操作；等待、halt和special驻留状态不得制造虚假IQ entry。
3. 控制微码和AHBD伪指令只能占slot0；被选中时slot1必须无效且PFU pop必须为0。
4. IQ不能接收当前微码项时，`ctl_st_de`、`ctl_inst_de`及其first/last/kill属性必须保持，不能跳过或重复一项。
5. `ST_WAIT`和`ST_LZWT`必须等IQ清空后才恢复普通PFU输入，保证handler指令不越过entry微码。
6. AHBD可获得高于控制微码的注入机会，但`msk_ahbd_de`指示的原子微码边界内必须禁止插入。
7. 微码操作不得按普通PC递增、普通BTAC学习或普通双发射处理；其架构边界由程序流状态与first/last属性决定。
8. entry/return的stack内容、SP变化、浮点frame选择、fault/retry和killability必须按架构语义实现；内部Thumb常量可以改变。
9. late arrival不得重复保存同一被中断上下文；tail-chain不得无意义地先恢复再重新保存同一frame。
10. 只有entry微码已经从IQ排空并允许PFU恢复后，handler中的Thumb指令才是普通PFU输入，并重新适用正常双发射规则；它们可以跟随仍在下游执行的更老微码，但不得越过或提前提交。

### 2.6 控制微码状态机

2.5节定义了微码的来源、数据流和架构语义；本节给出`cm7dpu_front_end`中`ctl_st_de`的具体状态规则。异常入栈、异常返回、lazy浮点上下文保存和sleep被拆成DPU可执行的内部Thumb形式操作。内部操作只进入slot0，并携带`first/last/kill-mask/lazy`状态，使`cm7dpu_prog_flow`能够把多个uOP视为一个受控架构动作。

#### 2.6.1 状态分组与跳转

![entry与lazy保存微码状态机](assets/dpu-microcode-entry-fsm.svg)

entry图把整数frame、full浮点frame、lazy浮点frame和fake entry分开。所有路径在注入完所需操作后进入`ST_WAIT`或`ST_LZWT`，直到IQ排空才回到普通取指。

![return微码状态机](assets/dpu-microcode-return-fsm.svg)

return图按full、partial、lazy和fake return分行，每条实线表示当前可读控制中的实际进入路径。`ST_POL2`有完整状态行为，但当前可读`mcode_op`映射和内部跳转没有进入边，因此重实现应保留其编码兼容性或用非法状态assertion覆盖，不能假定它在正常序列必经。

![sleep、halt与同步错误微码状态机](assets/dpu-microcode-special-fsm.svg)

特殊状态图显示sleep通过内部WFI进入等待，halt和同步错误驻留直到flush或新的mcode operation。三张图共同覆盖同一个`ctl_st_de`状态寄存器，不是三台并行状态机。

图按entry、三类return、lazy、fake frame修正、sleep/halt和同步错误分成多行。所有会注入指令的状态只在IQ允许push时前进；`ST_WAIT`与`ST_LZWT`在IQ清空前保持。`mcode_op_de_i`选择新序列首状态的优先级高于普通内部跳转，flush在没有新mcode时返回`ST_IDLE`。

#### 2.6.2 每个状态的行为

| 状态 | 本状态注入的语义 | 下一状态/退出条件 |
| --- | --- | --- |
| `ST_IDLE` | 不注入内部指令，允许正常PFU指令。 | 收到entry/return/lazy/sleep/halt操作后进入对应首状态。 |
| `ST_ENT0` | 根据FPCA和LSPEN选择整数frame、完整浮点frame或lazy frame。 | 无FP上下文→`ST_WAIT`；full→`ST_PUF1`；lazy→`ST_PUL1`。 |
| `ST_PUF1` | 在浮点frame之后压入整数frame。 | 注入后→`ST_WAIT`。 |
| `ST_PUL1` | lazy entry只记录浮点保存地址，再压入整数frame。 | 注入后→`ST_WAIT`。 |
| `ST_POF0` | full return先读取stack中的PC和xPSR。 | →`ST_POF1`。 |
| `ST_POF1` | 恢复其余整数寄存器。 | →`ST_POF2`。 |
| `ST_POF2` | 恢复浮点寄存器frame。 | →`ST_WAIT`。 |
| `ST_POP0` | partial return读取PC和xPSR。 | →`ST_POP1`。 |
| `ST_POP1` | 恢复整数寄存器并完成partial return。 | →`ST_WAIT`。 |
| `ST_POL0` | lazy return读取PC和xPSR。 | →`ST_POL1`。 |
| `ST_POL1` | 恢复整数寄存器但用无writeback形式，让DPU按lazy frame语义修正SP。 | →`ST_WAIT`。 |
| `ST_POL2` | 显式增加SP一个浮点frame；当前可读控制中未发现进入边，属于保留状态。 | 若被外部兼容逻辑置入则→`ST_WAIT`。 |
| `ST_LZY0` | 注入浮点寄存器lazy push，并标记first+last。 | →`ST_LZWT`。 |
| `ST_LZWT` | 不再注入，等待lazy项从IQ排空。 | IQ空→`ST_IDLE`。 |
| `ST_SLPE` | 注入内部WFI，使sleep进入仍遵循精确退休顺序。 | →`ST_WAIT`。 |
| `ST_HALT` | 不注入，阻止正常指令，等待halt退出操作。 | halt退出→`ST_IDLE`。 |
| `ST_MCHL` | sleep-on-exit使用的微码halt驻留态。 | 新mcode操作改变状态。 |
| `ST_SPEC` | PFU错误已转换为special uOP后驻留，等待程序流控制处理。 | flush或新mcode→对应状态。 |
| `ST_ENTF` | fake entry只减少SP，不产生memory access。 | →`ST_WAIT`。 |
| `ST_RETF` | fake full return增加完整frame大小。 | →`ST_WAIT`。 |
| `ST_RETI` | fake integer return增加整数frame大小。 | →`ST_WAIT`。 |
| `ST_RETN` | fake return不改变SP，但保留返回同步点。 | →`ST_WAIT`。 |
| `ST_WAIT` | 不注入，等待之前的微码全部离开IQ。 | IQ空→`ST_IDLE`。 |

状态中的硬编码Thumb值只是内部实现载体。重实现应按“压入/弹出哪些架构字段、SP变化多少、是否访问内存、是否原子”实现，不应仅复制常量而不解释其效果。

### 2.7 AHBD代理

AHBD调试请求通过DPU现有load/store通路访问memory。代理用公平计数避免持续调试流量完全阻塞软件执行；进入halt/sleep相关状态时可立即服务。load被合成为从调试地址读取并把结果送回debug的内部操作；store被拆成地址/数据可由DPU提交的内部操作。AHBD序列继承当前微码的killability，且不能插入必须原子连续的异常frame操作之间。

### 2.8 前端重实现检查项

1. 任意push/pop组合后，head0必须仍是全队最老entry。
2. slot1不能在slot0之前退休；slot0 interlock时slot1不得越过。
3. PFU error/protection/BTAC metadata必须与原指令entry原子移动。
4. 微码和AHBD只能占slot0，且同cycle不能混入PFU slot1。
5. flush后旧head/skid valid必须为0；数据位可不清零。
6. empty判定以head0 invalid为准；微码状态只能在IQ排空后恢复普通PFU输入。
7. IRQ/NMI请求本身不得被编码成普通IQ指令；只有被接受后的entry微码进入slot0。
8. handler中的Thumb指令只能在entry微码排空后恢复为普通PFU输入。
9. late arrival和tail-chain不得重复push已经存在或正在建立的异常stack frame。

## 3. 流水线与双发射

本章定义DPU从Decode (De，预译码)到Retire (Ret，退休观察)的双发射流水规则。

### 3.1 流水线总览

![DPU流水线](assets/dpu-pipeline-overview.svg)

图中每个阶段都可以同时携带slot0和slot1，但两个slot不对称：slot0更老，使用完整DP0，并独占DIV、LSM和多数special序列；slot1使用受限DP1，但在没有冲突时仍可使用共享MAC、FPU、第二访存通路或程序流单元。每级输出不是单纯的数据值，而是一组原子上下文：valid、uOP、源/目的指针、指令边界、PC关系、condition、访存属性、错误和是否可kill。

#### 3.1.1 每级详细规则

| Stage | 本级输入 | 本级处理 | 交给下一级 |
| --- | --- | --- | --- |
| De | PFU双槽、微码、AHBD请求、IQ空间。 | 源仲裁；预译码；保存错误、保护、长度和BTAC属性。 | 最多两个有序IQ entry。 |
| Iss | IQ head0/head1、寄存器堆、Wr转发NZCV、各执行单元busy/stall。 | 完整译码；读取A/B；构造立即数；检测RAW/WAW/端口/资源冲突；解析可提前判断的直接分支；决定0/1/2条。 | slot valid、uOP、A/B指针与值、四个destination、ALU/MAC/DIV/AGU/FPU控制。 |
| Ex1 | Iss操作数、Ex2/Wr旁路、LSM迭代状态。 | 选择最新操作数；AGU算有效地址和base writeback；shift/提取预处理；load/store发请求；启动DIV；形成MAC输入；必要时把slot1 replay到slot0。 | 地址、早期ALU数据、更新后的destination/LSM list、分支上下文、MPU P0请求。 |
| Ex2 | Ex1数据、MPU P1属性、LSU进度、FPU状态。 | DP0/DP1最终ALU；候选NZCV；分支方向/目标复核；访存目标和abort确定；MAC部分积进入Wr；DIV迭代保持本级。 | 整数结果、候选flags、load属性、branch prediction context、kill/quash候选。 |
| Wr | Ex2结果、LSU LS3 data/abort/retry、PPB data/error、MAC/DIV/FPU结果。 | 最晚分支解析；load swizzle；写回端口仲裁；提交NZCV/GE/Q、CONTROL和mask；精确异常判断；LSU/PPB commit。 | 已提交寄存器和状态；Ret使用的store data、PC、模式、追踪事件。 |
| Ret | Wr已提交上下文、store C-port数据、异常主控。 | 保持按程序顺序的退休观察；完成store数据相位；更新PC/IT/mode退休视图；生成ETM/DWT。 | 架构可见完成、trace和下一异常边界。 |

Wr在本文中同时承担writeback与精确提交判定。Ret主要是后置数据/观察级，不能把尚未在Wr通过kill/quash检查的操作变成架构可见。

#### 3.1.2 Ex1、Ex2与“Ex0”命名澄清

当前`cm7dpu` RTL的正式执行流水级是Execute 1 (Ex1，执行一级)和Execute 2 (Ex2，执行二级)，不存在名为Ex0的顶层流水级。源码信号后缀也使用`_ex1`、`_ex2`和`_wr`。如果其他文档把第一个执行cycle称为“EX0”，在本文中它对应Ex1；重实现接口和时序说明仍应采用RTL真实名称Ex1/Ex2，避免把“channel 0/slot0/DP0”误写成Ex0。

还必须把两个编号维度分开：DP0/DP1中的0和1表示并行执行lane；Ex1/Ex2中的1和2表示时间上先后两个stage。一条slot0指令可以在Ex1和Ex2连续使用DP0资源，一条slot1指令也会先经过Ex1上下文再在Ex2使用DP1；DP0不等于Ex1，DP1也不等于Ex2。

![不同指令在Ex1与Ex2的工作划分](assets/dpu-ex1-ex2-work.svg)

图从左到右按Iss、Ex1、Ex2、Wr/Ret排列，每一行是一类指令。所有stage框使用相同列坐标，表示正常发射的uOP在每个上升沿按顺序移动。某个框只写“传递PC/condition”或“同步pointer”，不表示该级不存在，而是表示这类指令在该stage没有主要算术工作，仍需保存完整指令身份。

Ex1是准备、早期变换和发起请求的stage，主要完成：

1. 锁存Iss选择后的A0/B0/A1/B1最新操作数，以及uOP、condition、PC关系和destination pointer。
2. 用AGU0/AGU1计算load/store address和base writeback value，并启动LSU地址请求与MPU P0 lookup。
3. 在DP0完成barrel shift、RBIT、部分REV/extend/extract、SAT×2等第一段处理。
4. 某些满足动态分配条件的简单ADD/SUB借用AGU0在Ex1提前完成，使结果可以更早forward；这不是所有ADD/SUB的固定路径。
5. 为MAC形成A/B输入和部分积准备，为DIV建立符号、CLZ和对齐状态，为LSM/LSD推进迭代控制。
6. 发现slot1无法继续使用第二lane时保存其上下文并触发replay，使其随后以slot0身份重新执行。

Ex2是主要最终整数执行、晚源读取和访问属性确认stage，主要完成：

1. `cm7dpu_dp0`的AU/LU、CLZ、bitfield、SIMD和saturation第一段，以及`cm7dpu_dp1_alu`的简单AU/LU。
2. 形成slot0/slot1整数结果和逐bit候选NZCV/GE信息；若结果已在Ex1提前形成，则在Ex2保持其指令上下文并选择该早期结果。
3. 读取C0/C1 late source，并用于store data、MAC accumulator、system或exception frame路径。
4. 接收MPU P1 memory attributes和abort，结合Ex1地址确定load/store是否可以继续。
5. 计算或复核寄存器branch target、condition和prediction结果，形成Ex2 force/kill候选。
6. DIV在此stage保持并迭代多个cycle直到done；Ex2不是固定单cycle通过的纯组合级。

##### 指令是否可以不经过Ex1

从流水线控制和指令身份角度，答案是否定的。正常从Iss发射的uOP必须经过：

```text
Iss -> Ex1 -> Ex2 -> Wr
```

即使某条简单逻辑指令的主要计算全部在Ex2，它仍要在Iss→Ex1上升沿把valid、A/B值、uOP、PC、condition、destination、异常属性和预测上下文锁存到Ex1，再在下一边沿交给Ex2。反过来，简单ADD若在Ex1通过AGU0提前得到结果，也仍要经过Ex2/Wr完成condition、kill、flag和架构提交检查，不能从Ex1直接写RF。

| 看起来像“没有使用某级”的情况 | 实际行为 | 不能做的错误实现 |
| --- | --- | --- |
| 普通AND/EOR的主要LU在Ex2 | Ex1传递并forward操作数与控制，Ex2完成LU。 | Iss直接写Ex2寄存器，绕过Ex1 stall/kill。 |
| ADD在Ex1提前完成 | 结果可早期forward，但指令valid继续进入Ex2/Wr。 | Ex1直接提交RF或NZCV。 |
| direct branch已在Iss解析 | Ex1/Ex2仍携带branch身份、prediction context和kill边界。 | Iss判断后删除该branch的下游上下文。 |
| FPU算术由外部FPU执行 | DPU中的control、valid和pointer仍同步经过Ex1/Ex2/Wr。 | 只让FPU前进而DPU pointer跳级。 |
| condition失败或指令被quash | 对应stage注入无副作用bubble或清除valid。 | 把“无效”解释成一条有效指令绕过某级。 |

因此，“有些指令不在Ex1做主要运算”是正确的；“有些指令不经过Ex1”是不正确的。只有kill/flush/quash把指令变成无效，或内部replay改变其重新进入slot的位置，才会改变正常推进，不存在有效uOP从Iss物理旁路到Ex2的通道。

### 3.2 双发射决策

![Iss发射判定流程](assets/dpu-issue-flow.svg)

发射必须保持顺序。slot0不能发射时slot1绝不能单独发射；slot0可发射但slot1不满足配对时，只消费head0并让head1成为下一cycle的slot0。slot1被限制不是性能提示，而是功能规则，因为它没有slot0的全部执行和读写资源。

#### 3.2.1 slot0 interlock主要来源

`slot0 interlock`表示：Iss中较老的slot0指令已经完成译码，但当前cycle不具备保证功能正确地进入Ex1的条件，因此发射控制暂时把它锁在Iss。这里的“安全”与security、MPU权限或memory protection无关；它表示如果在本cycle结束的时钟上升沿把该指令锁存到Ex1，能否保证指令拿到正确输入、使用未冲突的执行资源、不会覆盖尚未前进的Ex1内容，并保持程序顺序。这里的interlock是流水互锁，不是删除、kill或把指令判为无效；只要没有flush/exception取消该指令，它必须保持为IQ中最老的有效指令，并在互锁原因消失后重新参加发射判断。

“进入Ex1”不是只把一个valid位置1。在时钟上升沿，DPU必须把slot的uOP、A/B源值、源/目的寄存器指针、立即数、condition、访存和分支控制、错误属性及指令边界作为一个整体锁存进Ex1。以下五类条件全部满足，才能认为slot0可以在该边沿进入Ex1：

| 检查维度 | 可以进入Ex1的条件 | 不满足时若强行进入的错误 | 例子 |
| --- | --- | --- | --- |
| 操作数 | 每个Ex1需要的源值来自最新生产者，已经在RF中或位于明确支持的旁路点。 | 使用旧寄存器值，产生错误ALU结果、地址或store data。 | 较老`LDR R1,[R0]`的数据未返回时，`ADD R2,R1,#1`必须等待。 |
| NZCV/condition | 当前指令需要的N、Z、C、V已经提交或可以从合法stage旁路。 | 条件指令错误执行/取消，ADC/SBC/RRX使用旧carry，branch方向错误。 | 较老`CMP R0,R1`的新Z尚未可用时，`BNE label`不能按旧Z发射。 |
| 执行资源 | 指令需要的DIV、MAC、FPU、AGU、LSU或特殊序列资源可接受新操作。 | 覆盖前一条多cycle操作的内部状态，或两条操作争用同一物理端口。 | 第一条`UDIV`仍占用divider时，下一条`UDIV`不能启动。 |
| 下游容量 | Ex1现有内容将在该边沿前进或被合法清除，Ex1流水寄存器允许写入。 | 用新指令覆盖仍有效的Ex1指令及其控制；这是`stall_iss`负责的结构条件。 | Ex2因Wr stall不能前进，导致Ex1也不能离开时，Iss必须保持。 |
| 顺序与架构边界 | 没有更老异常微码、exclusive、system、replay或force边界要求该指令等待。 | 年轻指令越过较老事务，造成错误提交、重复副作用或不精确异常。 | exception entry微码正在更新LR/xPSR时，普通`BX LR`不能读取旧LR越过它。 |

因此，判断发生在Cycle N的组合逻辑中，真正的Iss→Ex1交接发生在Cycle N末尾的active clock edge。若五类条件满足，Ex1在该边沿接收完整指令上下文；若任一条件不满足，则slot0 valid和全部关联控制继续留在Iss/IQ，Ex1不得收到该指令的部分字段。等待周期数由数据返回和资源释放时间决定，不保证只停一拍。

```text
slot0可以进入Ex1 =
    操作数可用
    AND 所需NZCV可用
    AND 执行资源可接受
    AND Ex1可写入
    AND 不违反较老架构边界
    AND 未被kill/quash
```

上式是设计语义，不表示RTL必须集中实现为一个组合表达式。当前实现把“数据/资源/顺序不满足”归入`ilock0_iss`，把“Ex1因下游不能接收”归入`stall_iss`，再由两者共同阻止slot0发射。

![slot0 interlock对双发射的影响](assets/dpu-slot0-interlock.svg)

图的前三行分别展示无互锁、只有slot1自身互锁和slot0互锁。无互锁且满足双发射配对规则时，两项一起从Iss进入Ex1，IQ消费两个head。只有slot1自身互锁时，较老slot0仍可进入Ex1，IQ只消费第一项；原slot1保留并在下一cycle成为新的slot0，因此可以使用slot0的完整译码和执行资源重新判断。

第三行是slot0 interlock的关键规则。slot0是程序顺序中较老的指令，它不能发射时，即使slot1与当前数据依赖完全无关，slot1也不能单独越过。IQ不得pop任一项，head0/head1的指令身份、顺序及其错误、保护和预测side information必须保持一致。下一个cycle重新检查时，只有slot0的依赖、资源或序列化条件已经解除，才能发射slot0，并再次独立判断slot1是否可以配对。

RTL把“slot1自身不能发射”和“slot0阻止所有年轻指令”合并为最终slot1互锁：

```text
slot1最终互锁 = slot0互锁 OR slot1自身互锁

slot0发射 = slot0有效 AND NOT slot0互锁 AND NOT Iss整体stall
slot1发射 = slot1有效 AND NOT slot1最终互锁 AND NOT Iss整体stall
```

对应当前实现的精确关系是`ilock1_iss = ilock0_iss | ilock1nm_iss`；`ilock1nm_iss`只表示slot1自身的依赖、配对或资源限制。最终`issue_iss[0]`和`issue_iss[1]`还分别受`stall_iss`屏蔽，因此“没有interlock”也不代表下游一定能够接收。

图底部给出Read After Write (RAW，写后读相关)示例。较老`LDR`正在生成R1，而Iss的slot0是`ADD R2,R1,#1`。如果新R1尚未到达该操作允许使用的旁路点，读取Register File (RF，寄存器堆)只会得到旧值，所以slot0和slot1都停在Iss。等待时间不是固定一拍：load、MAC、DIV、FPU和PPB结果的产生stage不同，只有数据到达合法旁路点或已经写回后，互锁才能解除。解除后，`ADD`使用新R1发射；slot1还要重新通过配对检查才能同cycle发射。

slot0 interlock与相关控制的边界如下：

| 控制 | 产生原因 | Iss与IQ行为 |
| --- | --- | --- |
| slot0 interlock | slot0的数据、flag、资源或序列化条件尚未满足。 | slot0和slot1都不发射；两个IQ head保持，下一cycle重试判断。 |
| 仅slot1 interlock | slot1自身有依赖，或不满足双发射资源/指令类别限制。 | slot0单独发射；slot1留在IQ并成为下一cycle的slot0。 |
| `stall_iss` | Ex1或更下游无法接收新内容。 | 无论两个slot是否存在互锁都不发射，并保持Iss数据与控制。 |
| replay | 已经前进的slot1因执行限制需要改到slot0重新执行。 | replay项优先占用slot0路径；原IQ head保持，不能与普通slot0 interlock混为“丢弃后重取”。 |
| kill/flush | 更老异常、错误或程序流重定向使当前指令不再有效。 | 取消相应指令或清理前端；它不会在原因消失后继续重试。 |

重实现时，slot0互锁期间不仅要保持opcode或uOP，还要保持该entry的PC关系、源/目的寄存器指针、condition、访存属性、异常属性和预测上下文。不得让某些控制字段继续前进，也不得pop IQ后依赖另一个临时寄存器“记住”slot0，否则容易造成指令与side information错配。

slot0 interlock的主要来源包括：

1. A/B/C源寄存器依赖一个尚无可用旁路的数据，尤其load、MAC、DIV、FPU或VMRS结果。
2. Ex1/Ex2/Wr存在同一长延迟资源占用，新的DIV、LSM、PPB或FPU操作不能进入。
3. 前方指令将更新NZCV，而当前condition/ADC/SBC/RRX需要尚未形成的flag。
4. LSU/PPB/FPU向上游传播stall，或异常/branch flush正在改变流水状态。
5. replay中的slot1需要占用slot0，原IQ head暂时保持。

#### 3.2.2 双发射完整条件与逐类例子

双发射成立的定义是：同一个cycle内，IQ的两个独立架构指令分别作为slot0和slot1从Iss进入Ex1。不能因为Ex1内部恰好同时存在两个uOP，就把DIV、LDM/STM或LDRD/STRD等单条指令拆出的内部操作称为“双发射”。slot0和slot1也不是两条可以任意调换的lane：slot0始终较老且功能更完整，任何单发射结果都优先让slot0前进。

![slot0和slot1双发射完整判定顺序](assets/dpu-dual-issue-decision.svg)

该图从上到下表示每个cycle的组合判断顺序。首先确认IQ确实给出两个有效entry；随后确认Ex1可以接收并且较老slot0没有interlock。前两关失败时本cycle发射0条。之后所有关卡只决定slot1能否跟随：如果遇到强制单发射上下文、slot0独占序列、共享资源冲突、数据不可旁路或配置禁止，则只发射slot0，slot1保留在IQ并于下一cycle成为slot0。所有关卡都通过后，才允许两个slot同时进入Ex1。

##### 3.2.2.1 最终结果真值表

| slot0有效 | slot1有效 | `stall_iss` | slot0 interlock | slot1自身interlock | 本cycle结果 | 例子 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 任意 | 0 | 任意 | 任意 | 发射0条；空队列不能让slot1越过成为独立发射。 | IQ为空，或flush刚清除head0。 |
| 1 | 0 | 0 | 0 | 任意 | 只发射slot0。 | IQ只剩`ADD R0,R1,#1`一条。 |
| 1 | 1 | 1 | 任意 | 任意 | 发射0条，两个head及其控制保持。 | Ex1被LSU backpressure阻塞。 |
| 1 | 1 | 0 | 1 | 任意 | 发射0条，slot1不得越过。 | slot0的`ADD`等待较老`LDR`产生源寄存器。 |
| 1 | 1 | 0 | 0 | 1 | 只发射slot0，slot1留在IQ。 | slot0是独立`ADD`，slot1是当前不能放在第二lane的`UDIV`。 |
| 1 | 1 | 0 | 0 | 0 | 双发射，两个IQ head同时消费。 | 两条寄存器和资源独立的简单整数指令。 |

上述“slot1自身interlock”是所有非slot0原因的汇总，包括slot1无效、指令类别不支持、共享资源冲突、数据或flag不可旁路、FPU限制和ACTLR配置。当前RTL先形成该汇总，再把slot0互锁并入最终slot1互锁，因此顺序约束可以写成：

```text
slot1最终互锁 = slot0互锁 OR slot1自身互锁

发射0条：Iss整体stall OR slot0互锁 OR slot0无效
发射1条：slot0可发射 AND (slot1无效 OR slot1自身互锁)
发射2条：slot0可发射 AND slot1有效 AND NOT slot1自身互锁
```

##### 3.2.2.2 可以双发射的候选组合

“可以”表示RTL没有按指令类别直接禁止，仍要继续检查寄存器依赖、前序流水状态、condition、FPU和ACTLR。下表每个例子都假设slot0在左、slot1在右，两个entry有效且Ex1可接收。

| 组合 | 可双发射例子 | 必须同时满足的条件 |
| --- | --- | --- |
| 简单整数ALU + 简单整数ALU | `ADD.W R0,R1,#1`；`EOR R3,R4,R5` | 两条不争用受限shift/inline资源，不依赖对方未产生的结果，不需要尚未就绪的NZCV。 |
| 整数ALU + load | `EOR R0,R1,R2`；`LDR R3,[R4]` | load地址和base独立；ALU目的不覆盖slot1在Ex1需要的base。 |
| 整数ALU + store | `ADD.W R0,R1,#1`；`STR R2,[R3]` | store地址和store data不依赖slot0晚结果；不是exclusive或特殊store。 |
| 两个load | `LDR R0,[R1]`；`LDR R2,[R3]` | 两个地址生成通路可用，FPU未禁止slot1 load/store，且不是load-to-PC分支组合。 |
| load + store | `LDR R0,[R1]`；`STR R2,[R3]` | store不使用本cycle load的新R0，且两项都不是exclusive、多寄存器或doubleword序列。 |
| load + MAC | `LDR R0,[R1]`；`MLA R4,R5,R6,R7` | MAC源和accumulator都不读取load目的R0；不是store+MAC。 |
| 整数ALU + MAC | `EOR R0,R1,R2`；`MLA R4,R5,R6,R7` | 只有一个MAC，C读口不冲突，MAC accumulator不依赖不能旁路的slot0结果。 |
| 非branch + 单个branch | `ADD.W R0,R1,#1`；`BNE label` | slot0不更新该branch本cycle所需NZCV；无BTAC/IT冲突；ACTLR未禁止slot1 direct branch。 |
| 整数 + FPU | `ADD.W R0,R1,#1`；`VADD.F32 S0,S1,S2` | FPU存在且CPACR允许，FPU没有返回slot1 interlock，RF/FPU read pointer不冲突。 |
| slot0早期结果 + slot1消费者 | `ADD R0,R1,R2`；`EOR R3,R0,R4` | ADD被动态分配到Ex1早期加法路径，允许同cycle forwarding；若结果必须到Ex2/Wr才完成则禁止。 |
| 条件互斥的表面依赖 | IT block中的`ADDEQ R0,R1,R2`；`EORNE R3,R0,R4` | 两条condition被证明互斥、slot0不更新flags，未执行路径不会产生真实RAW。 |

![双发射允许、条件允许和禁止配对例子](assets/dpu-dual-issue-pairing-examples.svg)

图把常见配对分成三列。绿色列是结构上可双发射的候选，但不是绕过后续检查的白名单；黄色列强调同一对opcode会因寄存器、condition、旁路stage或FPU配置不同而改变结果；红色列是RTL明确强制单发射的类别。图中的汇编用于说明语义，实际判断使用decoder产生的uOP、源/目的指针、flag属性和控制字段，而不是比较助记符字符串。

##### 3.2.2.3 指令类别和共享资源限制

下表覆盖RTL明确把slot1锁住的主要结构条件。每一行成立时，只要slot0本身可发射，就先发射slot0，slot1留到下一cycle。

| 情况 | 是否双发射 | 例子 | 禁止原因 |
| --- | --- | --- | --- |
| 控制微码或lazy内部操作 | 否 | slot0正在执行exception entry push；slot1为普通`ADD` | 该entry不是普通软件指令，first/last、fault和stack边界要求单发射。 |
| AHBD调试伪指令 | 否 | debugger注入memory read；slot1为PFU `EOR` | 调试事务使用正常DPU通路但不是普通顺序程序项，必须保持独立完成边界。 |
| single-step模式 | 否 | debug step请求下，IQ同时有`ADD`和`SUB` | 每次只允许一条真实指令跨过精确debug观察点。 |
| 同步取指错误或slot1错误entry | 否 | slot0携带prefetch fault；slot1为普通`MOV` | 错误必须绑定到一条精确指令边界，年轻项不能同cycle推进。 |
| UNDEFINED/UNPREDICTABLE编码 | 否 | slot1 decoder识别出不支持编码；slot0为普通`ADD` | slot1先保留并转到slot0，以完整decoder和异常路径统一处理。 |
| DIV位于slot0 | 否 | `UDIV R0,R1,R2`；后跟`ADD R3,R4,#1` | divider只从slot0启动，并在slot1位置形成内部配套控制。 |
| Load/Store Multiple (LSM，多寄存器装载/存储) | 否 | `LDMIA R0!,{R1-R4}`；后跟`EOR R5,R6,R7` | 一条指令迭代多个寄存器和memory beat，独占slot0序列。 |
| Load/Store Doubleword (LSD，双字装载/存储) | 否 | `LDRD R0,R1,[R2]`；后跟`ADD R3,R4,#1` | 单条指令占用两个数据位置和多写回控制。 |
| Table Branch Byte/Halfword (TBB/TBH，表分支) | 否 | `TBB [PC,R0]`；后跟`MOV R1,R2` | 包含table load和branch两部分，slot1位置用于内部uOP。 |
| 系统寄存器读写 | 否 | `MRS R0,CONTROL`；后跟`ADD R1,R2,#1` | MRS/MSR/CPS更新或读取全局状态，必须形成单一架构边界。 |
| barrier、WFI/WFE等special操作 | 否 | `DSB`；后跟`LDR R0,[R1]` | 需要排空、sleep或序列化语义，前端会注入bubble/单发射控制。 |
| 两个branch | 否 | `BNE label0`；`B label1` | 程序流单元每cycle只解析和推进一个branch上下文。 |
| 两个store | 否 | `STR R0,[R1]`；`STR R2,[R3]` | store data和提交通路不支持同cycle两个独立store。 |
| store + MAC，任意slot顺序 | 否 | `STR R0,[R1]`；`MLA R2,R3,R4,R5` | store与MAC争用C读口、后置数据或写回资源。 |
| 两个MAC/MUL | 否 | `MUL R0,R1,R2`；`MLA R3,R4,R5,R6` | 只有一组共享MAC执行资源。 |
| 两个inline shift+ALU组合 | 否 | `ADD R0,R1,R2,LSL #1`；`EOR R3,R4,R5,LSR #1` | 两条同时要求受限inline shifter/ALU组合，DP1不能复制完整DP0路径。 |
| slot0必须使用Ex2 shifter，同时slot1也要shift | 否 | 复杂slot0 shift/bit操作；后跟`LSR R3,R4,#2` | slot0结果不能在Ex1完成，第二shift没有独立可用路径。 |
| 两条IT指令 | 否 | `IT EQ`；紧跟另一个`IT NE` | IT状态更新信息通路每cycle只能建立一个可靠边界；该软件序列本身也属于不可预测用法。 |
| exclusive/CLREX + slot1 load/store | 否 | `LDREX R0,[R1]`；`STR R2,[R3]` | exclusive monitor和LSU提交顺序必须保持原子语义。 |
| slot0产生内部bubble | 否 | 同步取指错误或exclusive store；后跟普通`ADD` | bubble用于隔离错误、重试或特殊边界，slot1不能跨过。 |
| RF读指针编码冲突 | 否 | slot0 MAC与slot1 VMOV同时要求同一受限C读口 | 物理RF读口没有足够复制，不能仅凭寄存器值相同推断可共享。 |

`双store`是明确禁止项，但`两个load`和`load + store`不是按类别直接禁止。这一区别必须保留；把所有“双memory操作”一律单发射会降低性能，把所有双memory操作一律放行又会破坏store和exclusive语义。

##### 3.2.2.4 branch、BTAC、IT和flag组合

| 情况 | 是否双发射 | 例子 | 判定说明 |
| --- | --- | --- | --- |
| slot0非branch、slot1单个direct branch | 条件允许 | `EOR R0,R1,R2`；`B label` | 只有一个branch，且BTAC、condition和ACTLR均允许时可配对。 |
| 两个branch | 否 | `CBZ R0,label0`；`BNE label1` | 无论条件是否可能互斥，程序流单元本cycle只接受一个branch。 |
| slot0 branch后slot1处于条件IT执行 | 否 | slot0 `B label`；slot1为IT控制下的`ADDEQ` | slot0可能改变后续指令路径，不能同时推进依赖IT状态的年轻指令。 |
| slot1中的CBZ/CBNZ位于IT block | 否 | IT block内把`CBZ R0,label`放在slot1 | 该组合属于不可预测边界，RTL保守地让其转到slot0处理。 |
| 两个slot都携带BTAC hit | 否 | 相邻两个fetch位置都命中BTAC side metadata | front end最终门控强制只发slot0，避免两个预测上下文同cycle推进。 |
| 一个BTAC hit与另一branch/BTAC上下文冲突 | 否 | slot0 BTAC hit；slot1又是`BNE label` | 一个预测目标可能已经改变顺序PC，第二branch不能共用同一program-flow入口。 |
| slot0 load-to-PC + slot1 load/store | 否 | `LDR PC,[R0]`；`LDR R1,[R2]` | load-branch的LSU commit和PC重定向不能与第二memory访问安全配对。 |
| slot0 flag-setting MUL + slot1 Bcc | 否 | `MULS R0,R1,R2`；`BNE label` | MAC产生的新NZCV到Wr才可用，没有slot0到slot1的即时flag forwarding。 |
| slot0改变carry + slot1依赖carry | 否 | `LSLS R0,R1,#1`；`RRX R2,R3` | slot1的RRX/ADC/SBC不能读取尚未形成的新C flag。 |
| slot1 branch只读取更老、已确定NZCV | 可以 | `ADD.W R0,R1,#1`；`BNE label` | `.W`例子不更新NZCV；branch使用进入本cycle前已经确定的flags。 |
| 两项共享IT info pipe | 否 | slot0为`MSR`/special info操作，slot1又是`IT EQ` | 单一IT/system info通路无法同时承载两项控制状态。 |

Direct branch（直接分支）指目标由当前指令立即数和PC计算的branch；indirect branch（间接分支）指目标来自寄存器、memory或其他运行时数据。这里不能把RTL的`br_dir`理解成“前向/后向”位：它表示direct类别；前向或后向预测则由branch offset的符号另行判断。

##### 3.2.2.5 数据相关与旁路组合

| 数据情况 | 是否双发射 | 例子 | 原因或放行条件 |
| --- | --- | --- | --- |
| 两项寄存器完全独立 | 可以 | `ADD.W R0,R1,#1`；`EOR R3,R4,R5` | 无RAW、flag或端口冲突。 |
| slot0简单ADD/SUB早期完成，slot1读取结果 | 条件允许 | `ADD R0,R1,R2`；`EOR R3,R0,R4` | 只有ADD/SUB被分配到Ex1早期路径且同cycle forwarding有效时放行。 |
| slot0复杂ALU/shift到Ex2才完成，slot1读取结果 | 否 | `UBFX R0,R1,#4,#8`；`ADD R2,R0,#1` | slot1在需要R0时结果尚未产生。 |
| slot0 load结果被slot1读取 | 否 | `LDR R0,[R1]`；`ADD R2,R0,#1` | load data不在同cycle Iss→Ex1旁路点，slot1下一cycle作为slot0重试。 |
| slot0 MAC结果被slot1读取 | 否 | `MLA R0,R1,R2,R3`；`EOR R4,R0,R5` | MAC结果在更晚stage产生。 |
| 较老Ex1/Ex2 load、MAC或VMRS结果尚未可旁路到slot1 | 否 | 前方`VMRS R0,FPSCR`尚在Ex2；slot1读取R0 | 当前slot0可以独立发射时，slot1仍必须等待自己的源数据。 |
| 较老MAC结果被slot1 load/store使用 | 否 | 前方`MLA R0,...`；slot1 `STR R0,[R4]` | MAC到LS地址/store-data路径没有所需旁路。 |
| slot0 load目的作为slot1 MAC accumulator | 否 | `LDR R0,[R1]`；`MLA R2,R3,R4,R0` | accumulator通过C路径读取，不能得到本cycle load结果。 |
| slot0饱和ALU结果作为slot1 MAC accumulator | 否 | slot0饱和运算写R0；slot1 `MLA R2,R3,R4,R0` | MAC看到的是饱和逻辑之前的候选路径，不能作为架构结果旁路。 |
| slot0整数结果被slot1 VMOV送入FPU | 条件通常不允许 | `ADD R0,R1,R2`；`VMOV S0,R0` | 当前实现对相关RF/C指针保守interlock；ACTLR[28]还可扩大该限制。 |
| exception微码仍在流水中且slot1读取LR | 否 | entry微码正在建立EXC_RETURN；slot1为`BX LR` | 微码对LR的更新到Ex2才可用，普通指令不能读取旧LR。 |
| 两条condition互斥且slot0不写flags | 条件允许 | `ADDEQ R0,R1,R2`；`EORNE R3,R0,R4` | 运行时最多一条真正执行，表面RAW不会发生；condition必须已可靠解析。 |
| 两条condition不互斥，或slot0更新flags | 否 | `ADDEQ R0,R1,R2`；`EORGT R3,R0,R4` | 两条可能都执行，或slot1 condition依赖slot0新flags，不能消除RAW。 |
| 两项需要同一个受限RF read encoding | 否 | slot0 MUL/MAC与slot1 FPU move同时请求同一C read pointer | 这是端口冲突，即使值已在RF中也不能同cycle读取。 |

Write After Write (WAW，写后写相关)不应被实现成“目的寄存器相同就一律禁止双发射”。DPU有多个写口，并按slot年龄控制最终可见顺序；某些目的覆盖反而说明较老中间值无需旁路。重实现必须使用带valid、condition、kill和destination类别的年龄比较，不能只比较两个4-bit寄存器号。

##### 3.2.2.6 FPU配置和ACTLR限制

| 配置/状态 | 受影响组合 | 例子 | 双发射结果 |
| --- | --- | --- | --- |
| FPU报告slot1 interlock | 任意slot1 FPU操作 | FPU仍忙时slot1为`VADD.F32` | 只发slot0，等待FPU允许后重试slot1。 |
| FPU报告slot1不能承载load/store | slot1 load/store | slot0 FPU操作；slot1 `LDR R0,[R1]` | 只发slot0。 |
| FPU不存在或CPACR禁止访问 | slot1 FPU编码 | slot1 `VADD.F32 S0,S1,S2`，但FPU disabled | 不双发射；该指令转到slot0后产生NOCP/UNDEFINED语义。 |
| 仅单精度FPU遇到双精度slot1指令 | slot1双精度FPU操作 | `VADD.F64 D0,D1,D2` | 不双发射；转slot0统一处理不支持指令。 |
| Auxiliary Control Register (ACTLR，辅助控制寄存器) bit[2]置1 | 所有组合 | 两条独立ADD | 全局关闭双发射，只发slot0。 |
| ACTLR[20]置1 | slot0为FPU | slot0 `VADD.F32`；slot1 `ADD` | 禁止任何指令跟在slot0 FPU后同cycle发射。 |
| ACTLR[19]置1 | slot0为MAC/MUL | slot0 `MUL`；slot1 `ADD` | 禁止slot0 MAC后的双发射。 |
| ACTLR[18]置1 | slot0为load-based branch | slot0 `LDR PC,[R0]`；slot1 `ADD` | 禁止该slot0类别后的双发射。 |
| ACTLR[17]置1 | slot0为indirect branch | slot0 `BX R0`；slot1普通指令 | 禁止indirect branch后的双发射。 |
| ACTLR[16]置1 | slot0为direct branch | slot0 `B label`；slot1普通指令 | 禁止direct branch后的双发射。 |
| ACTLR[25]置1 | slot1为FPU | slot0 `ADD`；slot1 `VADD.F32` | 禁止FPU进入slot1。 |
| ACTLR[24]置1 | slot1为MAC/MUL | slot0 `ADD`；slot1 `MUL` | 禁止MAC进入slot1。 |
| ACTLR[23]置1 | slot1为load-based branch | slot0 `ADD`；slot1为load-to-PC | 禁止该branch类别进入slot1。 |
| ACTLR[22]置1 | slot1为indirect branch | slot0 `ADD`；slot1 `BX R3` | 禁止indirect branch进入slot1。 |
| ACTLR[21]置1 | slot1为direct branch | slot0 `ADD`；slot1 `B label` | 禁止direct branch进入slot1。 |
| ACTLR[26]置1 | slot0 ADD/SUB到Ex1早期路径 | `ADD R0,R1,R2`；slot1读取R0 | 禁止动态早期分配，因此原本依靠同cycle旁路的相关配对会变成单发射。 |
| ACTLR[28]置1 | slot1 VMOV相关旁路 | slot0写R0；slot1 `VMOV S0,R0` | 使用更保守的相关检查，禁止该相关双发射。 |

ACTLR位是性能和勘误控制，不改变单条指令的架构结果。任何禁用位命中时都应退化为“slot0先发、slot1后发”，不能kill slot1，也不能把两条合并成一个uOP。

##### 3.2.2.7 可重实现判定顺序

```text
if Iss下游stall or slot0无效 or slot0自身interlock:
    本cycle发射0条
else:
    发射slot0

    if slot1无效:
        不发射slot1
    else if 非real/微码/AHBD/step/error上下文要求单发射:
        不发射slot1
    else if slot0属于DIV/LSM/LSD/TBB/TBH/system/bubble独占类别:
        不发射slot1
    else if 两指令存在branch/store/MAC/shift/exclusive/IT/读口资源冲突:
        不发射slot1
    else if slot1的数据、NZCV或condition不能从合法stage取得:
        不发射slot1
    else if FPU状态、CPACR或ACTLR禁止该配对:
        不发射slot1
    else if front end检测到两个BTAC hit需要单发射:
        不发射slot1
    else:
        同cycle发射slot1
```

上述顺序是语义优先级，不要求重实现复制一条超长组合OR表达式。可以分层计算`slot0_can_issue`、`global_single_issue`、`structural_conflict`、`data_conflict`、`config_conflict`和`slot1_can_issue`，但最终必须满足：slot1发射蕴含slot0发射；任何只禁止slot1的条件都不能误伤slot0；stall和slot0 interlock必须保持两个IQ head；单发射后原slot1必须成为下一cycle最老指令。

#### 3.2.3 依赖语义

Read After Write (RAW，写后读相关)要求消费者读取生产者的新值；Write After Write (WAW，写后写相关)要求较年轻写不能先于较老写可见。DPU按源指针与Ex1/Ex2/Wr的四个destination比较。若结果已经在允许的旁路点产生，选择旁路；否则interlock。

同cycle的slot0→slot1依赖只有明确支持的组合可以放行。普通DP0 Ex1可早期产生的结果可能给slot1使用，但MAC、load或需要Ex2/Wr才产生的结果通常不能。重实现不应把“组合逻辑算得出来”当作可旁路，必须按本文规定的可用stage保持原时序和异常顺序。

### 3.3 stall传播

stall由后向前级联：

```text
Wr不能前进
  -> stall_wr
  -> Ex2不能覆盖Wr，stall_ex2
  -> Ex1不能覆盖Ex2，stall_ex1
  -> Iss不能覆盖Ex1，stall_iss
  -> IQ head保持，De只可使用剩余skid空间
```

Wr stall包括DPU内部异常序列等待、FPU stall、PPB address/data ready不足和LSU LS3未ready。Ex2在此基础上还包括divider未完成、PPB read address未接受和load/store skid。Ex1再叠加FPU Ex1、LSU LS1与序列化条件。每级stall时必须同时保持valid和所有关联control/data；不能只保持uOP而让destination或error前进。

### 3.4 kill、quash与replay

| 控制 | 作用方向 | 必须屏蔽的副作用 |
| --- | --- | --- |
| `kill_iss/ex1/ex2/wr` | 由更老的异常、halt或程序重定向级联取消该级及年轻级。 | RF write、NZCV、LSU/PPB commit、BTAC update、FPU write、trace valid。 |
| `quash[slot]` | 选择性取消slot0或slot1，常见于condition fail、slot0 branch阴影和lazy push。 | 对应slot的一切写回和memory side effect；较老的另一个slot可保留。 |
| `flush_iss` | 清理前端IQ和预测side queue，要求重新建立指令流。 | 旧路径entry的valid和PFU pop关联。 |
| `replay` | 保存原指令身份，重新送入允许的slot/stage。 | 第一次尝试不能重复写回、重复commit或重复更新BTAC。 |

slot1 replay的典型原因是两个指令在Iss看似可配对，但Ex1出现更晚的序列化条件。此时slot0继续，slot1回到slot0位置；其PC、condition和BTAC context必须使用第一次发射时保存的值，不能按当前PFU队首重新计算。

### 3.5 正常双发射时序

![正常双发射时序](assets/dpu-timing-dual-issue.svg)

图中A和B在C1上升沿同时从Iss进入Ex1，A属于slot0且程序顺序更老。两个框始终占据完整cycle列，所有valid和控制只在上升沿跨级。C4进入Wr时可以使用不同写回端口同时更新两个目的寄存器，但若A在Wr产生异常或branch kill，B的write enable必须被屏蔽。

#### 3.5.1 load-use气泡

紧邻load的消费者不能假设Ex1或Ex2已有load data。load地址在Ex1产生，数据通常到Wr/LS3才可用；消费者若没有对应early-forward资格必须停在Iss，直到load data可旁路。stall只冻结消费者和更年轻项，较老load继续前进。

```text
Cycle       C0       C1       C2       C3       C4
LDR         Iss      Ex1      Ex2      Wr/data  Ret
dependent            Iss*     Iss*     Iss      Ex1

* dependent保持同一IQ head，不重复pop；C3使用Wr load forwarding后才发射。
```

#### 3.5.2 condition与NZCV

Iss可使用已经提交的`nzcv_ret`，也可使用Wr本cycle准备提交的`new_nzcv_wr`。只有当Ex1/Ex2没有更老的未完成flag writer时，`nzcv_ex2_v_iss`才允许条件分支在Iss解析。若更老flag仍在Ex1/Ex2，分支可以携带pending prediction继续，到Ex2或Wr再判断，不能读取未来值。

### 3.6 流水线不变量

1. slot1有效提交隐含slot0同一指令组已经有效或slot1被标记为slot0多uOP的一部分。
2. 任意stall期间，本级valid对应的所有元数据稳定。
3. 较年轻指令不能越过较老stall、exception或uncommitted PPB操作。
4. kill/quash优先于write enable与commit；stall不能让一次kill后的操作在释放时复活。
5. replay前一次尝试的副作用必须为零，但其指令身份和PC必须保持。
6. 同一架构指令拆成多个uOP时，只有`last`通过Wr后才形成完整退休边界。

## 4. 整数执行、寄存器堆与FPU边界

本章描述DPU的整数执行面，以及与FPU的边界。

### 4.1 整数数据通路

![整数执行与写回数据流](assets/dpu-integer-datapath.svg)

寄存器堆、旁路网络和多个执行单元共同组成DPU的数据面。slot0默认走完整DP0，slot1走精简DP1；MAC是两个slot受约束共享的资源，DIV只从slot0启动。load和外部FPU结果在Wr加入同一写回仲裁，因此“执行完成”和“架构写回”必须分开建模。

### 4.2 `cm7dpu_rf`规则

Register bank（寄存器bank）是共享一组地址选择和读写通道的寄存器存储集合。对本DPU必须区分两层含义：architectural register bank表示软件可见的R0-R14、MSP和PSP逻辑状态；physical register bank表示这些状态在电路中使用多少份flop阵列或复制RAM实现多端口。当前`cm7dpu_rf.v`为空文件，因此逻辑寄存器集合和端口行为可以确定，但物理复制份数、bank切分、read-during-write电路和门级写优先级不能从本代码包恢复。

![cm7dpu_rf逻辑register bank与多端口结构](assets/dpu-register-file-bank.svg)

图中央表示所有读写端口观察到的同一份逻辑架构状态，而不是A bank、B bank和C bank三份不同寄存器。R0-R12是普通通用寄存器，LR/R14单独保存链接或EXC_RETURN信息。架构指令访问R13/SP时，根据mode和`CONTROL.SPSEL`选择MSP或PSP；Handler mode固定使用MSP，Thread mode可选择MSP或PSP。PC/R15由`cm7dpu_prog_flow`管理，不存放在`cm7dpu_rf`中，需要读PC的指令由A/B forwarding mux选择独立PC数据。

图左侧是六个通用读端口和一个专用LR观察端口。A0/B0与A1/B1在Iss读取，分别为slot0和slot1准备主要计算输入；C0/C1的指针虽然由decoder在Iss产生，但地址沿流水保存，到Ex2才真正读取RF。C口推迟读取是因为store data、MAC accumulator和异常入栈数据不需要参与最早的地址/ALU关键路径，把它们放到Ex2可以减少Iss时序压力。LR专用输出只供程序流逻辑早期观察，不等同于可任意选择地址的第七个通用读口。

图右侧表示每组RF输出都先进入forwarding mux。若流水中更年轻位置的较老生产者已经算出新值，A/B/C应选择Ex1、Ex2或Wr结果，而不是RF中的旧值；若新值尚不可旁路，则产生interlock。图底部的W0-W3是四条Wr写通道，写地址为one-hot mask，并受valid、stall、kill和quash共同门控。

#### 4.2.1 A、B、C到底表示什么

A、B、C只是DPU内部对“第几个、在什么stage使用的源操作数通道”的命名，不对应Arm汇编中的固定寄存器编号，也不是三组不同存储bank。数字0/1通常表示DPU slot，但C口可被LSM、LSD、FPU和异常微码重新映射，因此不能把C0/C1永久解释为“slot0/slot1第三个源”。

| 读通道 | RF端口 | 读取stage | 一般用途 | 可由什么替代RF值 |
| --- | --- | --- | --- | --- |
| A0 | `ra0_addr/data` | Iss | slot0第一个主源；ALU operand A、load/store base、DIV/MAC输入。 | PC、AHBD地址、FPCAR、AGU/DP0/DP1、shift或Wr forwarding。 |
| B0 | `rb0_addr/data` | Iss | slot0第二个主源；ALU operand B、load/store index、shift输入。 | immediate、PC、AGU/DP0/DP1、shift或Wr forwarding。 |
| A1 | `ra1_addr/data` | Iss | slot1第一个主源；DP1 operand A、第二AGU base、MAC/FPU输入。 | PC、FPCAR、AGU/DP0/DP1、shift或Wr forwarding。 |
| B1 | `rb1_addr/data` | Iss | slot1第二个主源；DP1 operand B、第二AGU index、shift输入。 | immediate、PC、AGU/DP0/DP1、shift或Wr forwarding。 |
| C0 | `rc0_addr/data` | Ex2 | 晚到源0；store data、MAC低半accumulator、system/异常保存数据。 | DP0当前结果、Wr0-Wr3、Return PC或xPSR专用数据。 |
| C1 | `rc1_addr/data` | Ex2 | 晚到源1；第二store/MAC高半accumulator、64-bit/FPU/异常数据。 | DP0当前结果、Wr0-Wr3或xPSR专用数据。 |
| LR专用读 | `lr_data` | program flow需要时 | `BX LR`目标和EXC_RETURN识别。 | 不是通用mux端口；涉及未提交LR写时由interlock保证不读旧值。 |

其中“第一个源”“第二个源”“第三个源”只是帮助理解。decoder可以为了适配AGU、shift、MAC或内部微码交换源指针；重实现应执行decoder给出的`ra*`、`rb*`、`rc*`映射，不能仅按汇编文本中的操作数位置硬编码。

![A、B、C读通道的指令映射例子](assets/dpu-register-port-examples.svg)

图按五类指令说明端口用途。普通`ADD`只需要A和B两个早期源；indexed load把A当base、B当shifted index；immediate store的B不读取RF而选择立即数，待写memory的R0通过C晚读；`MLA`使用A/B作为两个乘数，C作为accumulator；exception entry微码使用A/B生成stack地址，再通过C路径把通用寄存器、Return PC和xPSR送到store数据流水。

这些例子也解释了C为什么不在Iss与A/B同时读取。`STR R0,[R1,#4]`的地址只依赖R1和立即数，必须尽早送AGU；R0是memory data，到Wr/Ret store data phase前保持正确即可，所以可以在Ex2经C口读取并继续forward。类似地，MAC乘法部分先使用A/B形成部分积，accumulator可以通过较晚的C路径加入。

#### 4.2.2 逻辑寄存器组织

| 逻辑状态 | 软件名称 | RF处理 |
| --- | --- | --- |
| 13个普通entry | R0-R12 | A/B/C均可寻址，W0-W3按目的mask写入。 |
| Main Stack Pointer | MSP，架构R13候选 | Handler mode固定选择；Thread mode在`SPSEL=0`时选择。低对齐bit按SP读取规则屏蔽。 |
| Process Stack Pointer | PSP，架构R13候选 | Thread mode在`SPSEL=1`时选择；Handler mode不能把它作为当前SP。 |
| Link Register | LR/R14 | 普通RF entry，另有`lr_data`专用观察输出。 |
| Program Counter | PC/R15 | 不在RF中；由`cm7dpu_prog_flow`保存，并在A/B或异常C数据mux中单独提供。 |
| 无寄存器 | `REG_NONE` | 5-bit pointer的无效编码；必须使one-hot read/write mask不命中任何有效entry。 |

RF接口使用16-bit one-hot read/write mask。架构R13访问在进入RF前已经解析为当前MSP或PSP backing entry；PC读取则绕过RF。因此“16个one-hot位置”不能直接解释为R0-R15全部存放在同一普通数组中，特别是PC不占普通RF entry。

#### 4.2.3 读端口时序

1. Decoder在Iss产生`ra0/rb0/ra1/rb1/rc0/rc1`五bit逻辑指针；高位还用于表示`REG_NONE`或特殊映射。
2. A/B指针立即转换成one-hot mask并在Iss读取RF，随后经过PC、immediate、Ex1/Ex2和Wr forwarding mux形成A0/B0/A1/B1。
3. A/B最终值在Iss→Ex1上升沿与uOP、condition和目的指针一起锁存，分别送DP0/DP1、AGU、shift、DIV、MAC或FPU。
4. C指针随指令从Iss经过Ex1到Ex2，在Ex2转换成one-hot mask读取RF，再经过DP0/Wr/PC/xPSR forwarding mux。
5. C数据在Ex2→Wr上升沿进入`c0_reg_wr/c1_reg_wr`，随后可继续到Ret作为store data，或在Ex2/Wr参与MAC、system和异常序列。
6. stall时，对应stage的指针、data和用途控制必须一起保持。不能让C pointer留在Ex2而store/MAC控制前进到Wr。

#### 4.2.4 写端口来源和仲裁

| 端口组 | 数量 | 使用stage | 语义 |
| --- | --- | --- | --- |
| A/B read | `ra0/rb0/ra1/rb1`四个 | Iss | 同cycle读取两个slot的主源操作数。 |
| C read | `rc0/rc1`两个 | Ex2 | 读取store data、MAC accumulator、异常frame或后置源；较晚读取可缩短Iss关键路径。 |
| write | `wr0..wr3`四个 | Wr/exception | 支持双发射、多结果、LDM和64-bit结果；每个端口有16-bit one-hot寄存器mask。 |
| LR read | 一个 | Iss program flow | 为BX LR早期目标检查提供Link Register (LR，链接寄存器)值。 |

| 写口 | 常规数据来源 | 特殊来源/用途 |
| --- | --- | --- |
| W0 | DP0结果 | MRS/VMRS结果，或MAC低32-bit。 |
| W1 | DP1结果 | exception/reset/debug RF写覆盖，或MAC低32-bit；特殊写与普通W1必须互斥。 |
| W2 | slot0 load data | STREX状态结果，或MAC高32-bit。 |
| W3 | slot1 load data | MAC高32-bit或第二晚结果。 |

物理寄存器指针是5-bit。`REG_NONE=5'b10000`表示无寄存器；R13会根据当前模式和SPSEL映射为 Main Stack Pointer (MSP，主堆栈指针) 或 Process Stack Pointer (PSP，进程堆栈指针)。重实现至少要保存R0-R12、LR、MSP和PSP；PC不作为普通RF entry写入，而由`cm7dpu_prog_flow`管理。

写口1还可被异常控制使用，用于reset时写MSP、exception entry写LR和debug写寄存器。设计保证该使用不与正常写口1冲突；重实现应显式assert这一互斥关系。MRS/MSR读出的系统状态在最后一级送写口0，不参与普通数据旁路。

#### 4.2.5 物理bank未知项与重实现规则

由于`cm7dpu_rf.v`为零字节，本文不能声称RTL使用“单个六读四写寄存器阵列”、三份A/B/C复制bank或某种特定SRAM macro。合理实现可以使用flop阵列直接构造多读口，也可以复制只读镜像并广播四个写口，但必须满足以下外部可观察规则：

1. 所有A/B/C和LR端口在没有forwarding时观察同一份已提交逻辑寄存器状态，不能因复制bank更新不同步而读到不同值。
2. 四个写口同cycle写不同entry时都必须生效；若可能写同一entry，最终结果必须按slot年龄和特殊写优先级确定，不能依赖未定义的RAM冲突行为。
3. read-after-write新值由顶层forwarding保证；RF内部采用read-first还是write-first可以替换，但不得绕过已有forwarding优先级。
4. MSP和PSP必须分别保存，逻辑R13按mode/SPSEL选择；PC必须继续由program-flow状态管理。
5. A/B在Iss读取、C在Ex2读取的stage边界不能随意移动，否则会改变interlock、load-to-store forwarding、MAC accumulator和异常frame时序。
6. 任意stall必须保持端口pointer与其所属指令身份；kill/quash必须屏蔽写口，不要求清零无效data bit。

### 4.3 旁路与interlock

旁路解决的是这一类问题：前序生产者（older producer）已经算出新值，但这个值还没有写入`cm7dpu_rf`，后序使用者（consumer）却已经需要它。DPU不等待“先写RF、再读RF”，而是在Iss、Ex1、Ex2或Wr之间直接转送结果。这只改变数据到达路径，不改变指令顺序、提交级或异常精确性。

![DPU forwarding选择机制](assets/dpu-forwarding-mechanism.svg)

图的左侧是后序使用者（consumer）的读取时间。A0/B0/A1/B1是Iss早读操作数，主要服务ALU、AGU、shift、DIV和FPU；C0/C1把寄存器指针随uOP推进到Ex2后才读，主要服务store data和MAC累加数。NZCV和LR有自己的可用性规则，不能当成普通A/B/C数据处理。

图的中间是程序顺序选择。对一个读寄存器指针（reader pointer），硬件先找“离当前指令最近的前序生产者（youngest older producer）”，再判断该生产者在使用者需要的stage是否已有效。已有效就forward；尚未有效就interlock；没有任何流水线内未提交生产者（in-flight producer）才读RF。因此“某个写口的指针相等”只是候选条件，不是最终forward valid。

图的右侧强调了一条不可放宽的规则：若最近的前序生产者尚未产生数据，不能跳过它去读程序顺序更早的生产者或RF中的旧值。例如`LDR R0,[R1]` 后紧跟`ADD R2,R0,#1`，load data未回来时，RF里即使还有旧`R0`，ADD也必须等待。

#### 4.3.1 选择规则：先确定最近的前序生产者，再判断结果是否可用

每个源操作数必须独立执行以下算法：

```text
1. 收集所有位于当前使用者之前、且声明会写该源寄存器的流水线内生产者。
2. 删除已确定condition fail、kill、quash或不会写该destination的候选。
3. 在剩余候选中，选择程序顺序上离当前使用者最近的一个。
4. 若该生产者在使用者需要的stage已result-valid，选择旁路数据。
5. 若该生产者还不能给出数据，保持使用者的pointer/uOP/PC并interlock。
6. 只有完全没有匹配的前序生产者时，才使用RF已提交值或专用操作数源。
```

对condition尚未解析的生产者，重实现应保守停顿，除非能证明生产者与使用者的条件互斥，或RTL已定义对应的conditional forwarding路径。不能只比寄存器号就放行。

![多次写同一寄存器时的前序生产者选择](assets/dpu-forwarding-nearest-producer.svg)

图中I1和I2都写R0，I3随后读R0。I1的`R0=1`已经有效，I2的load data却尚未返回，但I3仍必须先选中I2，因为I2是离I3最近的前序R0写者。这一步只确定“I3应该看到哪次写入”，不考虑哪个候选的数据更早就绪。

选中I2后才做可用性判断。当I2的`result-valid=0`时，I3 interlock；I1和RF旧R0都被屏蔽，不能成为“备用值”。当I2 load data返回后，旁路网络把I2的R0送给I3。只有I2最终condition fail或被kill，它不再是有效写者时，才会重新选择I1或RF已提交值。

#### 4.3.2 A/B早读与两次旁路检查

A/B pointer由decoder在Iss给出，RF同时输出已提交值。Iss forwarding mux可以改选以下来源：同cycle slot0明确支持的早期结果、位于Ex1的前序指令AGU writeback/shared shift/early ADD、Ex2的DP0/DP1结果、Wr的W0-W3结果，以及PC、immediate、AHBD address和Floating-Point Context Address Register (FPCAR，浮点上下文地址寄存器)等专用源。

操作数进入Ex1时还要再检查一次旁路。原因是生产者在使用者从Iss前进到Ex1的这一cycle内也在前进，它的结果可能刚好从“不可用”变成Ex2/Wr可用。因此重实现不能只在Iss做一个组合mux，然后无条件把数据保持到Ex1。

R13/SP经过forwarding时仍必须执行SP对齐规则，不能把旁路数据的低2-bit当作普通寄存器数据使用。PC、immediate、AHBD和FPCAR是operand mux源，不是“某个RF writer的forwarding”。

![ALU相邻依赖与同cycle slot0到slot1旁路](assets/dpu-forwarding-alu-examples.svg)

图的第一个例子是相邻cycle的`ADD`→`EOR`依赖。C1中I1位于Ex1，I2位于Iss；I2保留读R0的pointer，不把RF旧R0当成最终操作数。C2中I1进入Ex2并产生DP0结果，I2进入Ex1，Ex2到Ex1的旁路在这个cycle把新R0送给I2。因此，当I2的操作数使用时间与该旁路点匹配时，两条指令可以相邻cycle前进，不需要先等I1写RF。

图的第二个例子比较特殊：`ADD`和`EOR`在同cycle分别是slot0和slot1。只有slot0 `ADD/SUB`被动态分配给Ex1 AGU早期加法路径，且condition、ACTLR和配对规则都允许时，slot0的R0才能在C1 Ex1中送给slot1。若slot0结果要到Ex2/Wr才产生，或ACTLR[26]禁止该动态早期ADD，必须只发射slot0，slot1留在IQ中下一cycle重新判断。

#### 4.3.3 C口晚读与store-data forwarding

C0/C1的pointer在Iss确定，但数据到Ex2才读。这个时间安排允许store先用A/B计算地址，再给load-to-store依赖额外时间等待store data。例如：

```text
LDR R0, [R1]   ; 生产R0
STR R0, [R2]   ; A/B先计算R2地址，C口晚一些取R0
```

C口可从RF、当前DP0结果或Wr结果取数；在Wr-to-Wr的特殊情况中还会对C值再次更新。MAC accumulator、store data、exception frame以及部分FPU整数交换共享这类晚数据路径，所以C口竞争会导致单发射或interlock。

![load到store的C口晚旁路](assets/dpu-forwarding-load-to-store.svg)

图中I2是`STR R0,[R2,#4]`。它在C1 Iss已经拿到地址base R2，因此C2可以用`cm7dpu_agu`计算store address；此时并不需要R0数据已经可用。Iss只需要把“store data来自R0”的C pointer和I2的uOP、PC、slot身份一起传到Ex2。

C3中I1 load data从W2/Wr路径返回，I2的C forwarding mux使用R0 pointer选中该新数据，而不是RF旧R0。随后`cm7dpu_swizzle_store`按访问大小、地址低位和端序形成store data布局。图的下半部把地址、store data和commit画成三条独立路径：三者可以在不同stage产生，但到LSU/Store Buffer时必须属于同一条STR。如果load abort/retry或STR被kill，必须取消store commit，不能因为地址已发出就写memory。

#### 4.3.4 候选优先级与valid条件

| 候选来源 | 数据可能可用的位置 | 必须同时满足的条件 |
| --- | --- | --- |
| 同cycle的前序slot0 | Ex1早期AGU/ADD/shift路径 | 组合只在decoder和timing明确支持时放行；slot0 condition不能使数据失效。 |
| Ex1中的前序生产者 | AGU base writeback、shared shift、early ADD | destination匹配、对应result-valid，且该结果确实是使用者需要的格式。 |
| Ex2中的前序生产者 | DP0或DP1 | 同stage都命中同一reader时，程序顺序靠后的slot1/DP1优先；load/MAC即使有destination也可能尚无data。 |
| Wr W0-W3 | ALU、load、MAC、DIV、FPU、STREX status | 当前RTL同目的写口选择顺序为W3 > W1 > W2 > W0，实质是保留程序顺序靠后的slot1结果。 |
| RF | 已commit架构值 | 所有更近的流水线内生产者均不匹配时才可使用。 |

每个候选至少要带destination pointer、producer slot valid、result-valid、condition结果、kill/quash状态和程序顺序信息（instruction age）。同一指令可能占多个写口，例如long MAC的高/低32-bit；重实现必须对“该writer是否真正产生这个目的”建模，不能把uOP valid粗略当成所有写口valid。

#### 4.3.5 load、MAC、FPU和特殊寄存器限制

| 相关类型 | 可旁路情况 | 必须停顿或串行的情况 |
| --- | --- | --- |
| load → 简单ALU/shift | 对齐word load、非PPB、非跨界，且使用者属于RTL支持的简单路径时，可使用early load forwarding。 | byte/halfword整理、符号扩展、跨界、PPB、retry或data尚未有效时必须等待。 |
| load → store data | store地址可先计算，load data在C/late-forwarding路径到达。 | load abort/retry或数据到达超出允许窗口时不得提交store。 |
| MAC → 普通ALU | MAC结果在Wr可按高/低半送给A/B。 | 当前RTL不允许把MAC结果forward到AGU作load/store base，该相关必须interlock。 |
| DP0 → MAC accumulator | 可在受控情况下把DP0未经晚饱和处理的结果送给slot1 MAC。 | accumulator需要的结果类型或时间不支持时强制单发射。 |
| VMOV / VMRS | VMOV可把Wr整数数据送FPU；FPU返回的VMOV数据有专用valid/data旁路。 | VMRS读FPSCR属于Wr晚结果；FPU pointer冲突或slot1不支持的交换组合要停顿。 |

![普通load-use停顿与受限early load forwarding时序](assets/dpu-forwarding-load-use-timing.svg)

图的上半部是保守的普通load-use时序。`LDR`在C1 Ex1只产生地址，C2 Ex2仍在等待访存结果；`ADD`从C1开始保持在Iss，不重复pop IQ，也不读RF旧R0。示例中load data在C3进入W2/Wr并result-valid，因此`ADD`在C3通过Wr forwarding获得R0，在该cycle结束时才进入Ex1。

图的下半部是RTL专门支持的early load forwarding。当producer是对齐的32-bit word load、非PPB、非跨界，且consumer是允许在Ex2入口接收load data的简单ALU/shift时，consumer可从C1 Iss前进到C2 Ex1；C3 load data返回时，数据直接送到consumer的Ex2入口。这里的“early”是相对于“等load完全写RF后再读”，不表示load data在Ex1就已产生。

两个时序都假定LSU在图示C3返回数据且没有额外stall。实际cache miss、TCM wait、PPB握手、abort或retry可改变等待长度，但不改变选择规则：数据未result-valid时不得读RF旧值，也不得伪造forward valid。

NZCV forwarding与普通数据旁路分开。普通Wr flag writer可把新NZCV送给条件判断，但flag-setting MAC/MUL是晚结果且没有所有早期flag路径，所以紧邻Bcc可能interlock。exception entry对LR的特殊更新也不能假设有普通A/B旁路；当前路径只允许它在Ex2通过C口取得。

#### 4.3.6 完整reader/source覆盖矩阵

![DPU旁路完整覆盖矩阵](assets/dpu-forwarding-complete-matrix.svg)

图按“使用者在哪个reader取数”划分旁路，而不是只按producer是`ADD`、`LDR`或`MAC`划分。原因是同一个producer结果可能对A/B可用，对C口也可用，却不能进入AGU的时间紧张路径。只有同时确定reader、producer stage、result format和valid条件，才能判断某个例子是否真正可旁路。

矩阵中的A/B、early load、C、NZCV、DPU↔FPU和LR六行覆盖当前RTL所有可观察的reader/source类别。以下表进一步列出每个实际读取点的完整候选集：

| 读取点 | 完整候选数据源 | 选择后送往哪里 |
| --- | --- | --- |
| Iss A0 | RF A0、Ex1 AGU0/AGU1 writeback、Ex1 simple shift/REV、Ex2 DP0/DP1、Wr W0-W3。 | slot0 ALU/MAC/DIV/AGU的A路径。address feedback、AHBD address、FPCAR和PC是专用mux源，不是寄存器producer。 |
| Iss A1 | RF A1、Ex1 AGU0/AGU1 writeback、Ex1 simple shift/REV、Ex2 DP0/DP1、Wr W0-W3。 | slot1 ALU/MAC/AGU的A路径。FPCAR、PC和TBB/TBH专用源会屏蔽部分普通候选。 |
| Iss B0/B1 | RF B、Ex1 AGU0/AGU1 writeback、Ex1 simple shift/REV、Ex2 DP0/DP1、Wr W0-W3。 | ALU、shift、MAC、DIV或AGU index。immediate和PC是专用mux源。 |
| Ex1 A0 | Iss保存值、AGU0 base writeback、Ex2 DP0/DP1、Wr W0-W3、FPU-to-core VMOV data。 | DP0/AGU0/MAC/DIV后续路径。 |
| Ex1 A1 | Iss保存值、slot0 AGU writeback、slot0 shift/REV、Ex2 DP0/DP1、Wr W0-W3、FPU-to-core VMOV data。 | DP1、AGU1或slot1 MAC。 |
| Ex1 B0 | Iss保存值/地址、Ex1 shifter结果、Ex2 DP0/DP1、Wr W0-W3。 | DP0、MAC或DIV。 |
| Ex1 B1 | Iss保存值、slot0 AGU writeback、slot0 shift/REV、Ex2 DP0/DP1、Wr W0-W3。 | DP1或slot1 MAC。 |
| Ex2入口A/B early load | 原保存操作数、slot0 load word data W2、slot1 load word data W3。 | 只送受支持的简单ALU/shift和对应MAC operand mux；必须有专用early-forward control。 |
| Ex2 C0 | RF C0、PC/xPSR异常专用值、同cycle DP0结果、Wr W0-W3。 | store data低32-bit、MAC accumulator低32-bit、VMOV integer source或exception frame。 |
| Ex2 C1 | RF C1、xPSR异常专用值、同cycle DP0结果、Wr W0-W3。 | long MAC accumulator高32-bit、第二store/FPU数据或exception frame。 |
| Wr C0/C1晚刷新 | 保存的C值、W0、W2、W1；当前最后一级mux不提供W3候选。 | load-to-store双发射等需要在Wr再次修正C值的情况。 |
| NZCV | 已提交`nzcv_ret`、Wr `new_nzcv_wr`、slot0 Ex2的新flags。 | Iss/Ex2 condition、Bcc、IT、ADC/SBC/RRX。MULS/MAC flag有独立限制。 |
| FPU→DPU | FPU Ex1 `fwd-valid/data` channel0/channel1。 | VMOV FP-register-to-core-register的A操作数/写回路。 |
| DPU→FPU | Wr保存的C0/C1 integer data。 | VMOV/VMSR core-register-to-FPU整数数据。 |
| LR专用口 | `cm7dpu_rf.lr_data` 和`lr0_v_iss/lr1_v_iss`。 | `BX LR`类早期程序流判断。任一LR writer或mcode in-flight都使valid为0，该口没有普通Ex1/Ex2旁路。 |

A/B在Iss和Ex1有两次选择，但不表示两次可以选不同的架构writer。它们必须持续跟踪同一个最近前序生产者；第二次mux只是因为producer在这一cycle内从Ex1前进到Ex2或Wr，数据的物理来源发生了变化。

#### 4.3.7 全部旁路行为类别与指令例子

![旁路特殊路径与必须停顿的例子](assets/dpu-forwarding-special-cases.svg)

图补充了前面三张时序图没有单独画出的路径：AGU base writeback、Ex1 simple shift/REV、DP0-to-MAC accumulator、DPU与FPU双向交换、NZCV专用旁路，以及指针匹配但必须interlock的MRS、MAC-to-AGU和pending LR。下面三张表把图和前文的例子汇总成完整行为清单。

**A/B整数操作数与load early-forward清单**

| 编号 | producer→consumer类别 | 指令例子 | 数据路径与结果 |
| --- | --- | --- | --- |
| AB-0 | 没有in-flight writer | `ADD R0,R1,R2`，且R1/R2无pending writer | 直接读RF；这是baseline，不是forward。 |
| AB-1 | 同cycle slot0 early ADD/SUB→slot1 | slot0 `ADD R0,R1,R2`；slot1 `EOR R3,R0,R4` | slot0动态使用AGU在Ex1产生R0，slot1 A/B mux选新R0；ACTLR[26]、condition和配对必须允许。 |
| AB-2 | 同cycle slot0 simple shift/REV→slot1 | slot0 `LSL R0,R1,#2`；slot1 `EOR R3,R0,R4` | Ex1 shifter/REV结果给slot1；shift→ALU串联、复杂REV/SIMD不属于此类。 |
| AB-3 | 同cycle slot0 load/store base writeback→slot1非LS | slot0 `LDR R0,[R1,#4]!`；slot1 `ADD R2,R1,#1` | AGU0 Ex1的新base R1送slot1 A/B；LSM/LSD、condition或slot1也需要更早AGU base时可能禁止。 |
| AB-4 | 前一cycle Ex1 AGU writeback→后序A/B | `LDR R0,[R1,#4]!`；后续`ADD R2,R1,#1` | AGU0/AGU1 writeback候选在Iss或Ex1选中。 |
| AB-5 | 前一cycle Ex1 simple shift/REV→后序A/B | `LSL R0,R1,#2`；后续`ADD R2,R0,#1` | Ex1 `sh_dat`/REV result送A/B；仅在result-valid提前成立时放行。 |
| AB-6 | Ex2 DP0→后序A/B | `ADD R0,R1,R2`；`EOR R3,R0,R4` | consumer进Ex1时从DP0 Ex2取R0，不等W0写RF。 |
| AB-7 | Ex2 DP1→后序A/B | 前一双发射组的slot1 `ADD R0,R1,R2`；后续`EOR R3,R0,R4` | DP1 Ex2结果与DP0同时匹配时，程序顺序靠后的DP1优先。 |
| AB-8 | Wr W0→A/B | `ADD R0,R1,R2`；距离较远的`EOR R3,R0,R4` | W0通常是DP0或VMRS integer result；`w0_data_valid`和pointer匹配后选中。 |
| AB-9 | Wr W1→A/B | 前一slot1简单ALU或`UDIV R0,R1,R2`；后续`ADD R3,R0,#1` | W1承载DP1/除法最终整理结果；以实际destination与valid为准。 |
| AB-10 | Wr W2→A/B | `LDR R0,[R1]`；`ADD R2,R0,#1`；或`STREX R0,R2,[R1]`；`CMP R0,#0` | W2是slot0 load data或STREX status，也可是long MAC高半。 |
| AB-11 | Wr W3→A/B | 前一双发射组slot1 `LDR R0,[R1]`；后续`ADD R2,R0,#1` | W3是slot1 load data或对应MAC高半，同目的时它在Wr优先级最高。 |
| AB-12 | Wr MAC低/高半→A/B | `UMULL R0,R1,R2,R3`；`ADD R4,R1,#1` | MAC `r0/r1` 按目的寄存器映射到W0-W3候选；普通ALU可取，AGU load/store base不可取。 |
| AB-13 | FPU Ex1→core A | `VMOV R0,S0`；后续使用R0 | FPU提供`fwd-valid/data`，DPU A0/A1 Ex1 mux选中；fail/kill后不得保留valid。 |
| AB-14 | W2/W3 aligned-word load→consumer Ex2入口 | `LDR R0,[R1]`；简单`ADD R2,R0,#1` | 只限early load forwarding条件全部满足；consumer先进Ex1，load data在其Ex2入口选入。 |
| AB-15 | SP旁路 | `ADD SP,SP,#16`；后续读SP | 数据可从Ex1/Ex2/Wr候选取得，但旁路mux必须按SP语义屏蔽低2-bit。 |

##### 4.3.7.1 A/B操作数逐例流水线图

以下16张图与AB-0到AB-15一一对应。所有cycle都是相对周期；若producer受cache miss、除法迭代、FPU stall或下游back-pressure影响，对应保持周期可以向右延长，但stage框仍必须落在时钟边沿定义的cycle列内。

**AB-0：无流水线内writer**

![AB-0直接读取寄存器堆](assets/dpu-forwarding-cases/ab-00.svg)

图中ADD在C0的Iss直接读取RF，因为没有任何更近的in-flight writer。这个基线图强调：只有writer集合为空时才允许选择RF，不能把“某个writer尚未有效”误判成“没有writer”。

**AB-1：同组slot0早期ADD/SUB到slot1**

![AB-1同组早期ADD旁路](assets/dpu-forwarding-cases/ab-01.svg)

slot0和slot1在相同cycle列推进，数据箭头发生在两者的Ex1之间。只有slot0的加法被动态放入AGU早期路径并满足配对条件时，slot1才可在本组消费R0。

**AB-2：同组slot0简单shift/REV到slot1**

![AB-2同组shift旁路](assets/dpu-forwarding-cases/ab-02.svg)

slot0的simple shift/REV在Ex1产生结果，slot1的A/B mux同cycle接收。需要Ex2复杂处理的shift、REV或SIMD操作没有这条时序，必须拆开发射。

**AB-3：同组AGU base writeback到slot1**

![AB-3同组AGU base旁路](assets/dpu-forwarding-cases/ab-03.svg)

LDR写回寻址在Ex1形成的新R1直接送给slot1 ADD；绿色箭头传递的是更新后的base，不是load data。地址生成资源、condition或LSM/LSD限制不允许时，slot1仍需保留。

**AB-4：前一cycle AGU writeback到后序A/B**

![AB-4前序AGU旁路](assets/dpu-forwarding-cases/ab-04.svg)

consumer在C1 Iss时用reader pointer匹配当前Ex1的AGU writer，并选择R1_new。若该AGU结果没有result-valid，consumer保持原pointer和uOP，不得改读RF旧R1。

**AB-5：前一cycle simple shift/REV到后序A/B**

![AB-5前序shift旁路](assets/dpu-forwarding-cases/ab-05.svg)

consumer在Iss选择Ex1 shifter/REV已经完成的R0，并在下一cycle带入自己的Ex1。图中没有额外停顿的前提是producer被decoder标记为Ex1-done。

**AB-6：Ex2 DP0到后序A/B**

![AB-6 DP0 Ex2旁路](assets/dpu-forwarding-cases/ab-06.svg)

I2从Iss进入Ex1时再次检查writer，正好接收I1在DP0 Ex2形成的R0。第二次A/B选择使consumer无需等待I1进入Wr。

**AB-7：Ex2 DP1到后序A/B**

![AB-7 DP1 Ex2旁路](assets/dpu-forwarding-cases/ab-07.svg)

该时序与DP0类似，但producer来自前一双发射组中程序顺序较年轻的slot1。DP0和DP1同时命中同一reader时，选择DP1才能保持最近前序writer语义。

**AB-8：Wr W0到A/B**

![AB-8 W0旁路](assets/dpu-forwarding-cases/ab-08.svg)

producer到C3才在W0给出最终有效数据，consumer同cycle在Ex1选择W0。W0 pointer相等但data-valid、condition或kill不满足时，绿色路径必须关闭。

**AB-9：Wr W1到A/B**

![AB-9 W1旁路](assets/dpu-forwarding-cases/ab-09.svg)

W1可承载slot1简单ALU或DIV等最终结果，consumer在对应Wr cycle取得数据。图只表示写口时序，实际结果属于哪个destination仍由writer pointer与per-port valid决定。

**AB-10：Wr W2到A/B**

![AB-10 W2 load旁路](assets/dpu-forwarding-cases/ab-10.svg)

ADD在load data到达前连续保持在Iss，既不重复pop IQ，也不读取旧R0。C3的W2 result-valid使它在该cycle完成旁路选择，并在下一边沿进入Ex1。

**AB-11：Wr W3到A/B**

![AB-11 W3 load旁路](assets/dpu-forwarding-cases/ab-11.svg)

这是slot1 load经W3返回时的对应时序。若多个Wr端口声明同一destination，W3具有最高选择优先级，避免较老结果覆盖年轻结果。

**AB-12：MAC高低半到普通ALU**

![AB-12 MAC结果旁路](assets/dpu-forwarding-cases/ab-12.svg)

UMULL的高低32-bit按各自destination映射到Wr写口，后序普通ALU可从匹配写口取得其中一半。图中特意把consumer保持到MAC最终结果有效，不能把中间部分积当作架构值。

**AB-13：FPU到DPU专用Ex1通道**

![AB-13 FPU到DPU旁路](assets/dpu-forwarding-cases/ab-13.svg)

FPU在Ex1通过独立的fwd-valid/data通道把VMOV数据送入DPU对应路径。该图描述FPU-to-core边界；VMOV随后写R0以及再后序指令读取R0，仍分别遵守普通写回和A/B旁路规则。

**AB-14：word load到consumer Ex2入口**

![AB-14 early load旁路](assets/dpu-forwarding-cases/ab-14.svg)

consumer可以先通过Iss和Ex1，等load data在C3到达时才在自己的Ex2入口接收R0。只有对齐word、非PPB、非跨界且consumer具有专用入口mux时才允许这条绿色箭头。

**AB-15：SP旁路**

![AB-15 SP旁路](assets/dpu-forwarding-cases/ab-15.svg)

SP依赖使用普通A/B年龄和result-valid选择，但旁路值进入consumer前仍要执行SP低2-bit对齐语义。绕过RF不等于绕过架构上的SP格式约束。

**C口、MAC和FPU integer-data清单**

| 编号 | producer→consumer类别 | 指令/微操作例子 | 数据路径与结果 |
| --- | --- | --- | --- |
| C-0 | 无pending writer的RF C读 | `STR R0,[R1]` | C pointer在Ex2读`cm7dpu_rf`，然后进store swizzle。 |
| C-1 | Wr W0/W1 ALU→store data | `ADD R0,R1,R2`；`STR R0,[R4]` | store地址先算，C Ex2从Wr writer取R0。 |
| C-2 | Wr W2/W3 load→store data | `LDR R0,[R1]`；`STR R0,[R2]` | load-to-store晚旁路；必须跟踪正确的load channel和slot。 |
| C-3 | slot0 DP0 Ex2→slot1 MAC accumulator | slot0 `ADD R0,R1,R2`；slot1 `MLA R3,R4,R5,R0` | `allow_cfwd_mac_ex2`允许时，DP0未经不合法晚处理的结果送C0/C1 mux。 |
| C-4 | Wr MAC result→后续MAC accumulator | `UMULL R0,R1,R2,R3`；`UMLAL R0,R1,R4,R5` | C0/C1分别取低/高32-bit；若最近MAC尚未result-valid则停顿。 |
| C-5 | C0/C1组成64-bit accumulator | `UMLAL R0,R1,R2,R3` | C0=R0低半，C1=R1高半，两个pointer/valid必须属于同一指令。 |
| C-6 | PC/xPSR→exception frame | exception entry stacking micro-op | C0可选`pc_ret`或`psr_ret`，C1可选`psr_ret`；这是专用C mux源，不是RF writer。 |
| C-7 | core integer→FPU | `VMOV S0,R0`或VMSR类整数交换 | C0/C1在Wr的注册数据送FPU；不是FPU→DPU的Ex1旁路。 |
| C-8 | Wr-to-Wr晚刷新 | 同cycle/dual-issue load→store特殊配对 | 最后一级C mux可选W0、W2、W1；slot0 store/MAC、condition fail等情况会屏蔽该路。 |

##### 4.3.7.2 C口、MAC和FPU逐例流水线图

**C-0：无pending writer时读取RF C口**

![C-0 RF C口读取](assets/dpu-forwarding-cases/c-00.svg)

STR在Iss只保存C pointer，直到Ex2才真正读取R0并做store swizzle。晚读C口为地址计算与store data到达解耦提供了时序空间。

**C-1：W0/W1整数结果到store data**

![C-1 ALU到store data旁路](assets/dpu-forwarding-cases/c-01.svg)

STR在Ex1先完成地址计算，C3再从Wr写口取得ADD产生的R0。地址、旁路数据和store commit虽在不同stage形成，但必须保持同一条STR的身份。

**C-2：W2/W3 load结果到store data**

![C-2 load到store data旁路](assets/dpu-forwarding-cases/c-02.svg)

load data到达前，STR仍可沿地址路径前进；到C3才在C mux接收R0。load abort、retry或STR kill必须同时阻止最终store commit。

**C-3：同组DP0结果到slot1 MAC accumulator**

![C-3 DP0到MAC accumulator旁路](assets/dpu-forwarding-cases/c-03.svg)

slot0 DP0和slot1 MAC在同一个Ex2 cycle对齐，绿色箭头把R0送入C0/C1 accumulator mux。该路径只能在`allow_cfwd_mac_ex2`及相关配对条件成立时开放。

**C-4：MAC结果到后序MAC accumulator**

![C-4 MAC到MAC旁路](assets/dpu-forwarding-cases/c-04.svg)

前序UMULL在Wr同时提供高低半，后序UMLAL在自己的Ex2读取这两个C值。任一半尚未有效都不能拼成64-bit accumulator，consumer必须整体等待。

**C-5：C0/C1组成64-bit accumulator**

![C-5 双C口读取64位累加数](assets/dpu-forwarding-cases/c-05.svg)

没有pending writer时，C0和C1在同一Ex2 cycle分别读取低半R0与高半R1。两个pointer、valid和指令身份必须成对保持，不能跨指令拼接。

**C-6：PC/xPSR形成异常栈帧**

![C-6 异常专用C数据路径](assets/dpu-forwarding-cases/c-06.svg)

异常微码在Ex2从专用C mux取得`pc_ret`或`psr_ret`，而不是匹配某个普通RF writer。图中的紫色路径必须和stack地址、frame字段及commit一起受异常序列控制。

**C-7：DPU整数数据送FPU**

![C-7 DPU到FPU数据路径](assets/dpu-forwarding-cases/c-07.svg)

core-to-FPU的VMOV/VMSR先让DPU C数据推进到Wr并注册，再送FPU operand。它的方向和可用stage都不同于AB-13的FPU-to-core路径。

**C-8：Wr-to-Wr再次刷新C值**

![C-8 Wr阶段C值刷新](assets/dpu-forwarding-cases/c-08.svg)

C值在Ex2初选后仍可于Wr被W0、W2或W1更新，用于特定双发射load-to-store等组合。W3不在这个最终mux候选集中，屏蔽条件也必须在同一cycle生效。

**NZCV、LR和系统状态清单**

| 编号 | 类别 | 指令例子 | 数据路径与结果 |
| --- | --- | --- | --- |
| F-0 | 无pending flag writer | `BNE label` | 读已提交`nzcv_ret`。 |
| F-1 | Wr ALU flags→Iss/Ex2 | `CMP R0,R1`；后续`BNE label` | Wr `new_nzcv_wr`比`nzcv_ret`新，条件判断选新flags。 |
| F-2 | slot0 Ex2 flags→slot1 Ex2 | slot0 `CMP R0,R1`；slot1 conditional instruction | slot1在Ex2先看slot0已通过条件的新flags，再看Wr/已提交flags。 |
| F-3 | VMRS→APSR NZCV | `VMRS APSR_nzcv,FPSCR` | FPSCR[31:28]在Wr更新NZCV；早于Wr的consumer必须停顿。 |
| F-4 | MULS/MAC flags | `MULS R0,R1,R2`；`BNE label` | MAC N/Z直接到Ret更新，没有普通Wr-to-Iss early flag forwarding；BNE interlock。 |
| F-5 | ADC/SBC/RRX carry | `CMP R0,R1`；`ADC R2,R3,R4` | C flag必须来自最近合法flag writer；不能用旧carry。 |
| LR-0 | LR专用口早读 | `BX LR` | 只在Ex1/Ex2/Wr无LR destination且无mcode in-flight时，`lr*_v_iss=1`。 |
| LR-1 | pending LR writer | `MOV LR,R0`；`BX LR` | 专用LR valid置0，`BX LR`不能用RF旧LR早解析。 |
| LR-2 | exception/mcode LR update | exception entry产生EXC_RETURN | 不提供普通A/B旁路；需要时在Ex2通过C口或等写入完成后取得。 |

##### 4.3.7.3 NZCV与LR逐例流水线图

**F-0：读取已提交NZCV**

![F-0 已提交NZCV读取](assets/dpu-forwarding-cases/f-00.svg)

没有更近的pending flag writer时，BNE在Iss读取`nzcv_ret`中的Z。该图是flag网络的基线，与AB-0直接读RF的判断原则相同。

**F-1：Wr ALU flags到条件使用者**

![F-1 Wr flags旁路](assets/dpu-forwarding-cases/f-01.svg)

CMP在Wr给出`new_nzcv`时，BNE的后级condition判断选择新Z而不是旧`nzcv_ret`。在此之前，BNE只能携带pending状态继续或保持，不能提前使用旧flag作最终决定。

**F-2：同组slot0 flags到slot1**

![F-2 同组flags旁路](assets/dpu-forwarding-cases/f-02.svg)

slot0 CMP和slot1条件指令在Ex2列对齐，slot1优先查看程序顺序更老的slot0新flags。该绿色路径是独立flag mux，不通过A/B/C数据端口。

**F-3：VMRS到APSR NZCV**

![F-3 VMRS flags路径](assets/dpu-forwarding-cases/f-03.svg)

FPSCR的高4位到Wr才成为APSR NZCV候选，因此后序condition在此前保持。VMRS的FPU执行阶段不能被误当成core flags已经可用。

**F-4：MULS/MAC flags晚到达**

![F-4 MULS MAC flags停顿](assets/dpu-forwarding-cases/f-04.svg)

MULS/MAC的N/Z没有普通早期flag旁路，BNE连续保持到合法架构flags更新。MAC数据结果可能已经出现在某个写口，不代表其flags也具有相同时序。

**F-5：C flag到ADC/SBC/RRX**

![F-5 carry flag旁路](assets/dpu-forwarding-cases/f-05.svg)

ADC在执行时使用最近合法flag writer给出的C作为carry-in；SBC和RRX也依赖同一年龄选择。A/B已就绪不能解除这条独立flag相关。

**LR-0：LR专用早读口有效**

![LR-0 LR专用读取](assets/dpu-forwarding-cases/lr-00.svg)

无pending LR writer和异常微码时，`lr_v`允许BX LR在Iss读取`lr_data`并开始target判断。该端口不是普通A/B reader的别名。

**LR-1：普通LR writer使早读失效**

![LR-1 pending LR writer停顿](assets/dpu-forwarding-cases/lr-01.svg)

MOV LR仍在流水线中时，BX LR的专用valid持续为0；它不能从普通Ex2/Wr数据网偷取LR。writer完成并从pending集合消失后，BX LR才读取RF中的新值。

**LR-2：异常微码更新LR**

![LR-2 异常微码LR路径](assets/dpu-forwarding-cases/lr-02.svg)

exception entry产生EXC_RETURN期间，mcode in-flight同样屏蔽LR专用早读。异常值经专用C或写回路径完成后，后续LR流程才能继续。

#### 4.3.8 必须interlock或不属于DPU寄存器旁路的全部类别

| 编号 | 不能旁路或不属于本旁路的情况 | 正确行为 |
| --- | --- | --- |
| N-0 | 最近前序生产者存在，但`result-valid=0`。 | consumer interlock；不得选程序顺序更早的writer或RF旧值。 |
| N-1 | 同cycle slot0的结果需要Ex2/Wr，不是Ex1-done类别。 | 只发射slot0，slot1留IQ后重新判断。 |
| N-2 | byte/halfword、signed extend、unaligned、cross-boundary、PPB或需晚swizzle的load-use。 | 不使用aligned-word early path；等Wr整理后的result-valid。 |
| N-3 | 普通early load结果要送给DIV、复杂MAC、TBB/TBH或不支持的consumer stage。 | 按对应interlock control等待合法晚路径；不扩大AB-14。 |
| N-4 | MAC result作为后续load/store AGU base/index。 | RTL明确禁止MAC-to-LS AGU forwarding，load/store停顿到RF/合法路径可用。 |
| N-5 | MRS/MSR的system-register read data。 | MRS data在RF W0写入前最后一刻才mux进去，不参与普通W0 forwarding；后续consumer等正式RF更新。 |
| N-6 | VMRS result尚在Ex1/Ex2。 | 只在Wr可作为W0/NZCV来源，更早依赖interlock。 |
| N-7 | flag-setting MUL/MAC后紧跟条件指令。 | 没有普通早期flag forwarding，必须等MAC N/Z有效。 |
| N-8 | core→FPU VMOV的C数据与同cycle slot0 writer冲突，或FPU pointer/fail/kill不同步。 | 禁止slot1配对或interlock；不能直接把未注册Wr数据组合送FPU。 |
| N-9 | `BX LR`前存在pending LR writer或异常微码。 | 将LR专用读valid置0，禁止使用旧LR做早期branch target。 |
| N-10 | C口被store、MAC、VMOV或exception frame同时竞争，或Wr-to-Wr屏蔽条件成立。 | 强制单发射、保留slot1或使用合法晚路径。 |
| N-11 | producer condition尚未解析，且没有可证明的互斥condition forwarding。 | 保守interlock；condition fail确定后才删除该writer并重新选择。 |
| N-12 | producer被kill/quash，或load/MAC/FPU返回retry/fail。 | 屏蔽forward valid和RF write；replay后等新的result-valid。 |
| N-13 | LSM/LSD、cross-word、TBB/TBH、AHBD或exception micro-op复用A/B/C通路。 | 使用各自的专用mux和序列化规则，不把通路复用误解为通用旁路。 |
| N-14 | PC、immediate、AHBD address、FPCAR、xPSR或AGU address feedback。 | 这些是专用operand source，不是某条前序指令的RF destination forwarding。 |
| N-15 | load-to-PC、TBB/TBH table data形成branch target。 | 走program-flow/branch target路径，不当成通用寄存器A/B/C旁路。 |
| N-16 | Store Buffer→load的memory forwarding、LFB forwarding、D-cache hit data。 | 它们属于LSU/DCU/cache内的memory-data forwarding；DPU只在返回数据成为W2/W3 result-valid后参与寄存器旁路。 |

##### 4.3.8.1 不可旁路、停顿与专用源逐例流水线图

以下17张图把“为什么不能旁路”画到具体cycle。红色箭头或红框表示当前数据不能被consumer采用；后续绿色或蓝色路径表示result-valid、条件解析、资源释放或RF正式更新后，consumer如何恢复前进。

**N-0：最近writer的result-valid为0**

![N-0 result-valid未成立](assets/dpu-forwarding-cases/n-00.svg)

consumer连续保持到最近writer真正给出结果，期间更老writer和RF旧值都被屏蔽。C4释放时仍使用同一个reader pointer和指令身份。

**N-1：slot0结果不是Ex1-done**

![N-1 slot1拆开发射](assets/dpu-forwarding-cases/n-01.svg)

同组slot1不能消费要到Ex2才形成的slot0结果，所以C0只发slot0。原slot1留在IQ，下一cycle成为slot0后再通过正常Ex2到Ex1路径取得数据。

**N-2：load需要晚对齐、扩展或协议处理**

![N-2 复杂load-use停顿](assets/dpu-forwarding-cases/n-02.svg)

byte、halfword、signed extend、unaligned、cross-boundary或PPB load在Ex2的原始数据不是最终架构值。consumer必须等Wr完成整理，不能使用AB-14的early入口。

**N-3：consumer执行单元没有early load入口**

![N-3 不支持的early load consumer](assets/dpu-forwarding-cases/n-03.svg)

即使producer是合格word load，DIV、复杂MAC、TBB/TBH等consumer也没有对应的Ex2 operand mux。它们保持到合法Wr旁路或RF读取时刻。

**N-4：MAC结果不能进入load/store AGU**

![N-4 MAC到AGU禁止旁路](assets/dpu-forwarding-cases/n-04.svg)

MAC在Wr已有R0时，后序普通ALU可能能够旁路，但LDR的AGU base路径仍被明确禁止。图中LDR等待R0正式进入RF后才开始地址计算。

**N-5：MRS不进入普通W0旁路网**

![N-5 MRS结果等待RF](assets/dpu-forwarding-cases/n-05.svg)

MRS在RF写入前最后一级才把system-register值mux到W0输入，普通W0 datapath并不携带该值。后序ADD必须等下一cycle从RF读取新R0。

**N-6：VMRS只在Wr产生core可见结果**

![N-6 VMRS Wr可用时刻](assets/dpu-forwarding-cases/n-06.svg)

VMRS在FPU Ex1/Ex2期间仍没有core可用的W0或NZCV；consumer保持到Wr。到Wr后，整数destination和flags分别进入其合法选择路径。

**N-7：MULS/MAC flags没有早期旁路**

![N-7 MAC flags interlock](assets/dpu-forwarding-cases/n-07.svg)

BNE不能把MAC数据写口误当成flag来源，也不能读取旧`nzcv_ret`。它只在MAC N/Z完成架构更新后释放。

**N-8：core-to-FPU C资源冲突**

![N-8 FPU数据路径序列化](assets/dpu-forwarding-cases/n-08.svg)

slot0占用共享C或写回资源时，年轻VMOV保持在IQ，不与slot0混发。资源释放后它以完整指令身份重新发射，并在自己的Wr把C数据送FPU。

**N-9：pending LR writer屏蔽BX LR**

![N-9 pending LR target停顿](assets/dpu-forwarding-cases/n-09.svg)

Ex1、Ex2或Wr中的LR writer都会使`lr_v=0`，因此BX LR保持。直到新LR在RF稳定，program-flow才重新读取target。

**N-10：多个操作竞争C0/C1**

![N-10 C口结构冲突](assets/dpu-forwarding-cases/n-10.svg)

store、MAC、VMOV或exception frame即使数据独立，也可能因共享C口无法同cycle推进。较老项先使用资源，年轻项留在IQ或replay上下文中等待。

**N-11：producer condition尚未解析**

![N-11 condition未决停顿](assets/dpu-forwarding-cases/n-11.svg)

condition未决时consumer不能猜测producer会不会写R0。解析为pass后选择新值；解析为fail后删除这个writer，并重新选择更老writer或RF值。

**N-12：kill、retry或fail撤销forward valid**

![N-12 replay前禁止旁路](assets/dpu-forwarding-cases/n-12.svg)

失败尝试产生的总线数据不具有架构效力，绿色valid必须被撤销。只有replay重新执行并给出新的result-valid后，consumer才可释放。

**N-13：特殊微操作复用A/B/C通路**

![N-13 特殊序列占用操作数通路](assets/dpu-forwarding-cases/n-13.svg)

LSM/LSD、cross-word、TBB/TBH、AHBD和异常微码按各自序列占用通路。物理mux复用不能被解释为面向任意普通consumer的通用forwarding。

**N-14：PC、立即数等专用operand source**

![N-14 专用操作数来源](assets/dpu-forwarding-cases/n-14.svg)

PC、immediate、AHBD address、FPCAR、xPSR和AGU feedback由当前指令直接选择，不参与前序writer年龄比较。它们仍要随本指令的stall、kill和valid保持一致。

**N-15：load-to-PC与TBB/TBH target路径**

![N-15 程序流target专用路径](assets/dpu-forwarding-cases/n-15.svg)

memory或table返回值形成新PC并触发program-flow redirect，而不是送入普通寄存器consumer。错误路径清理和异常优先级由branch target路径处理。

**N-16：LSU/DCU内部memory forwarding**

![N-16 memory forwarding与DPU边界](assets/dpu-forwarding-cases/n-16.svg)

Store Buffer、LFB或cache数据先在LSU/DCU侧完成选择、对齐和检查；这段紫色路径不进入DPU reader。只有最终W2/W3 result-valid才通过绿色寄存器旁路送给DPU consumer。

以上“全部”指当前RTL可观察的reader/source行为类别全部覆盖，不要求重实现照抄为降低fanout而复制的每一根one-hot control wire。只要对上述每一行都有对应的正例、反例和assertion，就能验证重实现没有遗漏任何旁路语义。

#### 4.3.9 旁路、停顿、kill与replay的配合

1. interlock时，使用者留在当前stage，reader pointer、uOP、PC、slot程序顺序和condition不得漂移。
2. 生产者被kill/quash后，它不再是writer；使用者下一次判定可读RF，或选择程序顺序更早的真正生产者。
3. 生产者返回retry时，该次data-valid不得用于forward；生产者保留或replay后重新产生数据。
4. 若slot1因旁路或资源限制无法与slot0同时继续，slot0可前进，slot1必须保留完整指令身份后replay，不得改用RF旧值勉强执行。
5. 重实现应对每个reader检查forward-select one-hot，并断言“有未完成的最近前序生产者时不得选RF”。

### 4.4 DP0与DP1

DP0和DP1是同一个cycle内可并行工作的两条整数执行lane，不是前后相接的两个stage。DP0主要承载较老slot0并提供完整整数功能；DP1主要承载较年轻slot1，只实现高频、简单、适合双发射的算术/逻辑功能。MAC、DIV、AGU、LSU和FPU是与两条整数lane协作的独立或共享资源，不能简单归类成“DP1的一部分”。

![DP0与DP1执行能力对比](assets/dpu-dp0-dp1-comparison.svg)

图上半部分先强调lane和stage是两个维度。左侧`cm7dpu_dp0`自身跨Ex1、Ex2和Wr，Ex1放置barrel shifter等前处理，Ex2放置完整AU/LU、CLZ、SIMD和saturation主逻辑，Wr完成晚saturation/Q与写回。右侧`cm7dpu_dp1_alu`的主要组合逻辑位于Ex2，只包含简单adder和Logic Unit；slot1在Ex1仍有操作数、valid和control流水寄存器，并可在受控条件下使用DP0 Ex1的共享shift/AGU结果。

图下半部分把AGU、MAC、DIV、LSU/MPU和外部FPU画成协作资源。两个slot都有地址生成机会，但两个store、两个MAC等组合仍受结构限制；DIV只允许slot0启动；FPU有自己的执行流水，DPU负责同步控制和指针。slot1遇到DP1不支持的操作时不会使用错误的精简功能，也不会丢弃，而是先只发射slot0，让原slot1留在IQ并在下一cycle成为slot0。

| 能力 | DP0 | DP1 | 对双发射的影响 |
| --- | --- | --- | --- |
| 对应主slot | slot0，程序顺序较老 | slot1，程序顺序较年轻 | slot0不能发射时slot1不得越过。 |
| Decoder | full decoder | small decoder | small decoder发现不支持/UNDEFINED组合时让slot1转到slot0重判。 |
| Arithmetic Unit | 完整AU，支持ADD/SUB/ADC/SBC、比较、SIMD算术等控制 | 简单32-bit adder，支持mask、invert、carry-in | 两条简单算术可并行，复杂算术只走DP0。 |
| Logic Unit | 完整LU及复杂结果选择 | 简单LU | 两条简单逻辑可并行。 |
| shift/rotate | Ex1完整32-bit barrel shifter，支持LSL/LSR/ASR/ROR/RRX及复杂组合 | 没有独立完整shifter；有限操作使用共享shift结果或Ex2 late-B/RRX选择 | 两条同时要求完整shift资源时强制单发射。 |
| bit manipulation | RBIT、REV、extend/extract、mask、bitfield、CLZ | 不具备完整对应单元 | 这些指令必须成为slot0。 |
| SIMD/saturation | 支持SIMD lane、GE、signed/unsigned saturation和Q | 不支持完整SIMD/saturation | SIMD/DSP复杂操作不能依赖DP1。 |
| flag | 产生完整NZCV、GE和Q相关候选 | 产生简单算术NZCV或逻辑N/Z候选 | Wr按slot年龄和per-bit mask提交。 |
| DIV/system/特殊序列 | slot0独占或由周边专用单元协作 | 不支持启动 | 强制单发射。 |
| MAC/FPU/load-store | 通过共享MAC、FPU和AGU0/LSU0协作 | 在配对允许时通过共享MAC、FPU和AGU1/LSU1协作 | 是否双发射还需检查资源、依赖和ACTLR，不能只看DP1 ALU。 |

#### 4.4.1 `cm7dpu_dp0`

DP0是主整数通路，覆盖除multiply、USAD类和DIV专用单元之外的大多数整数data-processing。源码明确把内部资源分成三个stage：

| DP0内部stage | 真实功能 | 输出给下一stage的内容 |
| --- | --- | --- |
| Ex1 | 32-bit barrel shifter、RBIT wiring、QDADD/QDSUB使用的SAT×2、extend/extract第一段；接收A0/B0和部分C控制。 | shifted/rotated data、carry及valid、bit permutation、扩展中间值、Ex2控制。 |
| Ex2 | Arithmetic Unit、Logic Unit、CLZ、extend/extract第二段、mask/bitfield select、saturation第一段、NZCV/GE候选。 | `dp0_out_ex2`、branch candidate、flag候选和Wr控制。 |
| Wr | SIMD saturation第二段、Q等晚状态与最终`dp0_out_wr`。 | W0写回数据和架构flag更新候选。 |

某些简单ADD/SUB可以不走DP0 Ex2 adder的普通长路径，而由AGU0在Ex1动态计算。该优化由`use_agu_for_add0_ex1`控制，并受ACTLR[26]、前序依赖和AGU占用限制。早期结果可以给同cycle或下一stage消费者forward，但该指令仍经过Ex2/Wr完成提交。

Arithmetic Unit (AU，算术单元)通过操作数mask、取反和carry-in统一实现ADD、SUB、ADC、SBC及比较；Logic Unit (LU，逻辑单元)实现AND、BIC、EOR、ORR、ORN、MOV、MVN及特殊结果选择。结果控制决定更新NZCV、GE或Q，不能由opcode名称直接推断所有flag更新。

#### 4.4.2 `cm7dpu_dp1_alu`

DP1的源码用途说明是“Simple ALU. No shift or SIMD”。它的核心组合逻辑位于Ex2，包括一个33-bit adder、一个复用`cm7dpu_alu_lu`的简单Logic Unit、operand mask/invert、carry-in和有限late-B选择。它可以产生算术NZCV和逻辑N/Z候选，但没有DP0的完整barrel shifter、CLZ、bitfield、SIMD和saturation子模块。

DP1并不表示slot1在Ex1完全没有状态。A1/B1、condition、destination和DP1 control仍从Iss进入Ex1，再在Ex1→Ex2边沿送入`cm7dpu_dp1_alu`。某些允许配对的slot1操作可以使用DP0 Ex1 shifter产生的共享B结果；RRX在Ex2用forward后的C flag替换B bit[31]。共享路径有冲突或结果不可及时获得时，slot1 interlock，不能假设DP1拥有第二套完整shifter。

DP1结果在Ex2形成并锁存到Wr的`dp1_reg_wr`，最终通过W1写口提交。condition失败、kill、quash或Wr stall必须同时门控结果和flag update；不能因为DP1是年轻lane就提前写RF。

#### 4.4.3 slot1不支持时如何处理

| 场景 | 本cycle | 下一cycle | 例子 |
| --- | --- | --- | --- |
| slot1为DP1支持的简单指令且无冲突 | slot0和slot1双发射。 | 两条分别沿DP0/DP1继续。 | 独立`ADD` + `EOR`。 |
| slot1指令需要完整DP0 | 只发射slot0，slot1不pop。 | 原slot1成为slot0，使用full decoder和DP0。 | slot1为`UDIV`、复杂bitfield或SIMD。 |
| Iss允许配对但Ex1发现晚序列化条件 | slot0继续，保存slot1 replay上下文。 | replay项占slot0路径重新执行。 | 晚发现的LSM/LSD或共享资源限制。 |
| slot1源数据尚不可旁路 | 只发射slot0。 | 原slot1成为slot0并重新检查依赖。 | slot1读取slot0 load结果。 |
| slot0本身interlock或下游stall | 两条都不发射。 | 两个IQ head保持原顺序。 | slot0等待较老MAC/load结果。 |

重实现不能通过“把所有指令都复制一套DP0”随意扩大DP1能力，因为这样会改变原设计的双发射时序、interlock可见周期和性能事件；也不能把DP1进一步缩减成只支持单一ADD，因为独立简单AU/LU配对是本设计预期行为。功能兼容实现应按decoder类别、共享shift规则、数据旁路和ACTLR开关复现是否允许slot1发射。

### 4.5 `cm7dpu_mac`

Multiply-Accumulate (MAC，乘加)模块支持普通乘法、长乘、双16-bit乘法、32×16、累加/减和 Sum of Absolute Differences (SAD，绝对差之和)。

| 阶段 | 处理 |
| --- | --- |
| Iss | 译码乘法类型、signed、negate、round、accumulator mask和结果高/低选择。 |
| Ex1到Ex2 | 将32-bit操作数拆成16-bit半字，计算最多四个无符号16×16部分积，并为signed乘法生成修正项。 |
| Ex2到Wr | 对齐部分积、修正项、round和64-bit accumulator，用压缩树/加法器形成最终64-bit结果。 |
| Wr | 输出低32位、高32位以及N、Z、Q；由目的指针决定写一个或两个寄存器。 |

Q表示饱和/乘加溢出累积状态，通常只置位不由普通未溢出MAC清零。N/Z只在decoder标记的指令上更新。MAC被kill时，部分积寄存器可以保留旧数据，但valid和写回使能必须失效。

### 4.6 `cm7dpu_div`

Divider使用radix-4迭代，每个STP cycle产生2-bit商。除法只在slot0启动，活动期间Ex2等待`div_done`，阻止后续占用同一结果路径。

![除法状态机](assets/dpu-divider-fsm.svg)

#### 4.6.1 状态说明

| 状态 | 进入时捕获/计算 | 驻留与输出 | 退出条件 |
| --- | --- | --- | --- |
| `DIV_ST_IDL` | 无活动除法；可预捕获A/B。 | `done=0`，不占用有效结果。 | 新unsigned除法→CLZ；signed→MOD。 |
| `DIV_ST_MOD` | 记录商符号和余数符号，对负操作数取绝对值。 | 一cycle预处理。 | 无条件→CLZ。 |
| `DIV_ST_CLZ` | 分别计算被除数和除数的leading-zero count。 | 得到有效位差和迭代长度。 | →SHR。 |
| `DIV_ST_SHR` | 对齐除数，初始化部分余数、商和step计数。 | 除数为0或无需迭代时准备特殊结果。 | zero/完成→DON；否则→STP。 |
| `DIV_ST_STP` | 比较部分余数与D/2D，选择0/1/2/3作为下一2-bit商并更新余数。 | 每cycle递减剩余step。 | `last_cyc`→DON，否则保持STP。 |
| `DIV_ST_DON` | 商和余数已形成，按原符号产生最终结果或negate标志。 | `div_done=1`；保持结果直到流水接受或clear。 | 下一操作/clear后回IDLE。 |

`div_clear`由Ex2 kill驱动，从任意活动状态立即放弃当前除法。除数为0产生`div_by_zero`，最终是trap还是架构定义结果由CCR配置和`cm7dpu_prog_flow`在Wr决定。

### 4.7 NZCV、GE与Q

NZCV是Application Program Status Register (APSR，应用程序状态寄存器)中的四个条件标志。它们记录最近一条被允许更新flags的指令所产生的结果特征，供后续条件执行、branch和带carry的数据运算使用。NZCV不是四个通用寄存器，也不保存完整运算结果；每个flag只有1 bit，并且可以按bit独立更新或保持旧值。

![NZCV条件标志的产生、提交与使用](assets/dpu-nzcv-primer.svg)

图的上半部分从左向右表示候选flag的数据来源、四个flag的基本含义和消费者。算术、逻辑、shift、MAC、FPU/system操作并不是一律覆盖四个bit；decoder同时生成每个bit的set-mask，未被选择的flag保持原值。图中部的四个例子强调C和V是两套不同的数值解释：C服务unsigned carry/borrow，V服务signed范围溢出，两者可以一个为1而另一个为0。

图的下半部分表示当前DPU时序。Iss先识别流水中是否存在更老flag writer；Ex1形成shift carry等早期信息；Ex2分别形成slot0和slot1候选NZCV；Wr再用valid、condition、kill、quash和更新mask决定是否写入架构寄存器`nzcv_ret`。Wr的新flag可以forward给Iss，但Iss不能越过仍在Ex1/Ex2的更老flag writer去读取“未来值”。异常entry把最终架构状态作为xPSR的一部分压栈，异常return可以从stack恢复。

#### 4.7.1 N、Z、C、V分别表示什么

| Flag | 全称 | 置1条件 | 不能误解为 |
| --- | --- | --- | --- |
| N | Negative，负数标志 | 对更新N的普通32-bit结果，结果bit[31]为1。 | “发生错误”或“运算一定按signed执行”；它只复制结果最高位，signed解释由后续指令决定。 |
| Z | Zero，零标志 | 对更新Z的结果，32个bit全部为0。 | “比较相等专用位”；ADD、SUB、AND、shift等得到0也可置Z。 |
| C | Carry，进位标志 | 加法产生第33位进位；减法没有借位；flag-setting shift把最后移出的bit写入C。 | signed overflow；C主要描述unsigned运算和shift carry。 |
| V | Overflow，有符号溢出标志 | signed结果超出32-bit补码范围。 | 第33位进位；V与C可以不同。 |

对32-bit加法，C表示完整数学结果是否大于`0xFFFFFFFF`；V表示把输入解释为signed时，两个同号输入是否得到异号结果。例如`0x7FFFFFFF + 1`没有unsigned第33位进位，所以C=0，但它从最大signed正数变成`0x80000000`，所以V=1。

对减法`A-B`，C使用“NOT borrow”规则：若A在unsigned意义上大于等于B，不需要借位，C=1；若A小于B并发生借位，C=0。这个定义使`CMP A,B`之后可以直接用C判断unsigned大小关系。V仍只判断signed减法是否越过`-2^31`到`2^31-1`范围。

#### 4.7.2 典型计算例子

| 运算 | 32-bit结果 | N | Z | C | V | 解释 |
| --- | --- | --- | --- | --- | --- | --- |
| `0xFFFFFFFF + 1` | `0x00000000` | 0 | 1 | 1 | 0 | unsigned产生第33位进位；按signed是`-1+1=0`，没有溢出。 |
| `0x7FFFFFFF + 1` | `0x80000000` | 1 | 0 | 0 | 1 | 没有unsigned进位；最大signed正数加1发生溢出。 |
| `1 - 2` | `0xFFFFFFFF` | 1 | 0 | 0 | 0 | unsigned发生借位；signed结果`-1`仍可表示。 |
| `2 - 1` | `0x00000001` | 0 | 0 | 1 | 0 | 没有借位，所以C=1。 |
| `0x80000000 - 1` | `0x7FFFFFFF` | 0 | 0 | 1 | 1 | unsigned没有借位；最小signed负数减1发生signed溢出。 |
| `LSLS R0,R1,#1`且R1 bit[31]=1 | 移位后的32-bit值 | 取结果bit[31] | 结果为0时置1 | 1 | 保持或按编码规则 | 最后移出的原bit[31]成为shift carry。 |

`CMP R0,R1`在flags意义上执行`R0-R1`，但丢弃算术结果，只保留NZCV；`CMN`类似执行加法比较。`TST`和`TEQ`丢弃逻辑结果，通常更新N/Z，并按shifter规则决定C，V保持。重实现不能只按助记符推断“四个flag全写”，必须使用decoder给出的per-flag update mask。

#### 4.7.3 哪些指令更新NZCV

| 指令类别 | 常见例子 | 更新行为 |
| --- | --- | --- |
| 显式flag-setting算术 | `ADDS`、`SUBS`、`ADCS`、`SBCS` | 根据最终算术结果更新N/Z/C/V。 |
| compare/test | `CMP`、`CMN`、`TST`、`TEQ` | 不写通用目的寄存器，只更新编码规定的flags。 |
| flag-setting move/shift | `MOVS`、`LSLS`、`LSRS`、`ASRS`、`RORS` | N/Z来自结果，C通常来自最后移出的bit，V通常保持。 |
| 某些MUL/MAC | `MULS`等decoder标记形式 | 通常更新N/Z；本实现的MAC flag到Wr才可用，没有普通早期旁路。 |
| FPU到APSR传送 | `VMRS APSR_nzcv,FPSCR` | 从FPSCR复制N/Z/C/V到APSR。 |
| system/debug/exception return | `MSR APSR_nzcvq,...`、debug PSR write、unstack xPSR | 按专用mask或stacked xPSR恢复相应flag。 |
| 不更新flags的普通形式 | `ADD.W R0,R1,#1`等没有S语义的编码 | 通用结果正常写回，NZCV保持原值。 |

Thumb窄编码是否隐式更新flags，以及IT block内是否抑制普通S语义，由decoder和IT状态共同决定。设计中已经存在`set_nzcv0/1`与逐bit set-mask，重实现不得用“看到ADD就更新”或“没有写字母S就不更新”的字符串规则替代decoder语义。

#### 4.7.4 条件码如何读取NZCV

| 条件 | 成立条件 | 常见含义与例子 |
| --- | --- | --- |
| EQ | `Z=1` | equal；`CMP R0,R1`结果为0后`BEQ`。 |
| NE | `Z=0` | not equal；比较结果非0后`BNE`。 |
| CS/HS | `C=1` | unsigned higher or same；A-B没有借位。 |
| CC/LO | `C=0` | unsigned lower；A-B发生借位。 |
| MI | `N=1` | minus；结果最高位为1。 |
| PL | `N=0` | plus or zero；结果最高位为0。 |
| VS | `V=1` | signed overflow发生。 |
| VC | `V=0` | signed overflow未发生。 |
| HI | `C=1 AND Z=0` | unsigned strictly higher。 |
| LS | `C=0 OR Z=1` | unsigned lower or same。 |
| GE | `N=V` | signed greater than or equal。 |
| LT | `N!=V` | signed less than。 |
| GT | `Z=0 AND N=V` | signed strictly greater than。 |
| LE | `Z=1 OR N!=V` | signed less than or equal。 |

ADC把旧C作为加法进位输入；SBC按`A-B-(1-C)`使用C，因此C=1表示不额外借1；RRX把旧C送入结果bit[31]，同时把原操作数bit[0]移入新C。这些不是condition判断，但同样会形成NZCV数据依赖。

#### 4.7.5 当前DPU的产生、旁路与提交规则

1. Iss根据decoder输出识别slot0/slot1是否会写flag，并检测Ex1、Ex2和特殊MAC路径中是否仍有更老pending flag writer。
2. 普通AU、LU和shift在Ex2形成`new_nzcv_0_ex2`与`new_nzcv_1_ex2`候选；N/Z/C/V各自有独立update enable，不要求四个bit一起更新。
3. Wr只有在对应slot valid、condition通过、未kill、未quash且Wr可推进时才更新`nzcv_ret`。stall期间候选与控制必须保持，不能重复或提前提交。
4. 两个slot同cycle都合法更新同一个flag时，slot1在程序顺序上更年轻，因此该bit最终采用slot1值；若slot1只更新N/Z而slot0更新C/V，则每个bit按各自mask合并。
5. Wr本cycle将提交的`new_nzcv_wr`可forward给Iss和Ex2消费者。Ex1/Ex2仍存在更老flag writer时，Iss不得读取旧`nzcv_ret`冒充最新值。
6. flag-setting MAC是晚结果特例，普通条件指令不能依赖不存在的早期MAC flag forwarding；需要时产生interlock。
7. exception return、VMRS/MSR和debug写可从专用数据源更新NZCV；其优先级必须屏蔽被kill的普通slot更新。exception entry只读取已经提交的架构NZCV并把它写入stacked xPSR。
8. 当前RTL在reset时把`nzcv_ret`清为`4'b0000`。重实现应保持该内部复位值，并保证reset期间没有伪flag update。

Iss条件判断不读取“未来Ex2值”。它只在没有Ex1/Ex2 pending flag writer时，选择已提交`nzcv_ret`或Wr本cycle准备提交的`new_nzcv_wr`。因此紧邻`CMP`的`BNE`通常不能在Iss使用已经提交的旧Z；它携带pending condition继续，在更晚stage用CMP产生的新NZCV复核。隔开足够距离后，`BNE`可以直接使用Wr forwarding或已经提交的`nzcv_ret`。

#### 4.7.6 GE与Q的区别

Greater-than-or-Equal flags (GE，SIMD逐lane大于等于标志)是4-bit SIMD lane状态，不属于NZCV。它由DP0特定SIMD操作更新，供SEL等指令逐lane选择数据。

Q是sticky saturation标志，用于记录饱和或某些DSP/MAC操作曾经发生溢出。“sticky”表示普通未溢出运算不会自动把它清零；软件、异常恢复或debug/system写按架构规则更新。异常返回和debug写xPSR可以一次恢复或覆盖NZCV、GE和Q，但被kill的普通指令不得产生任何flag副作用。

### 4.8 外部FPU边界

FPU不是`cm7dpu`子模块。DPU输出129-bit control bus、Iss操作数valid、整数forward、kill/fail/stall和debug指针；FPU返回各stage valid、stall、forward data、写指针、FPSCR和out-of-order-in-flight状态。

`kill`从FPU流水中完全移除uOP；`fail`只取消数据处理结果，但保留pointer pipe，用于条件失败或特殊异常返回场景。DPU与FPU的slot指针必须同步跨Ex1/Ex2/Wr，64-bit VFP load/store拆拍时还要单独stall FPU slot1。

Floating-Point Status and Control Register (FPSCR，浮点状态控制寄存器)在Wr由VMRS/VMSR、异常返回、debug或新上下文初始化更新。Floating-Point Default Status Control Register (FPDSCR，浮点默认状态控制寄存器)只在新浮点上下文第一次使用时提供默认控制位。

### 4.9 缺失RTL的补齐原则

移位器和SIMD饱和模块源码缺失时，应按Armv7-M架构逐条实现LSL/LSR/ASR/ROR/RRX的0、1、31、32和大于32边界，以及signed/unsigned lane saturation。接入DPU时保持原端口stage：主shift在Ex1形成data/carry，第二shift实例在Ex2服务slot1/特殊情况，SIMD saturation结果在Wr决定Q。

## 5. Load/Store与内存接口

本章描述DPU与LSU、MPU和PPB的访存规则。

### 5.1 访存主路径

![DPU访存路径](assets/dpu-memory-flow.svg)

DPU计算地址、访问大小、byte strobe和提交条件；LSU负责实际ITCM/DTCM/AHBP/D-cache/AXI访问；MPU返回权限和memory attributes；PPB处理系统控制空间。地址、slot身份、目的寄存器、错误和数据必须沿同一事务移动。

### 5.2 地址生成与目标选择

两个`cm7dpu_agu`分别服务slot0和slot1。AGU计算`A ± B`作为pre-index地址或base writeback值；post-index访问使用原base作为地址，同时保留加减结果用于writeback。LSM把低两位清零并按beat递增。

DPU按地址高位和配置窗口选择目标：

| 地址区域语义 | 目标 |
| --- | --- |
| `0x00000000`附近且落入配置ITCM窗口 | ITCM，通过LSU/TCU路径的数据侧访问。 |
| `0x20000000`附近且落入配置DTCM窗口 | DTCM。 |
| `0x40000000`附近且落入配置AHBP窗口 | AHBP。 |
| 普通code/SRAM/external区域 | D-cache/AXI路径。 |
| `0xE0000000`系统控制空间 | PPB；vendor system子区可转AHBP。 |

选择由实际配置size/mask决定，不能只用最高3-bit固定映射。DPU同时产生可能目标request mask，最终chip-select还结合TCM/AHBP是否实现。

### 5.3 推测性读取、目标纠错与commit

本DPU支持推测性读取，但“推测”必须拆成两个不同概念：

1. **指令级推测**：load在到达Wr并最终commit前，已经可以把地址和读请求送入LSU，以隐藏cache/TCM/外部memory延迟。它后来若被branch、exception、condition fail或kill取消，LSU返回的数据不得成为架构结果。
2. **目标路径预测**：完整`base ± offset`尚未算出时，DPU先用A/base的高地址预测Chip Select (CS，目标片选)；Ex1再用AGU完整地址比较并纠错。这是一个timing optimization，不是猜测load data。

DPU负责产生操作数、地址、访问类型、目标候选、kill/flush和commit；LSU负责实际驱动TCM、D-cache、AHBP或外部memory读取；MPU负责返回权限和memory attributes。因此“DPU发出了推测load”不等于“DPU内部实现了cache”，也不等于该load已经commit。

![DPU推测性读取与纠错流程](assets/dpu-speculative-read-flow.svg)

图中主路径从Iss开始。load的A通常是base，B是offset或index；如果base来自前序指令（older instruction），必须先由第4.3节的forwarding机制取得真实新值。DPU在时间紧张的早期路径上用A的高位选出候选CS和request，同时让AGU计算完整有效地址。

Ex1对比预测目标与完整地址目标。若相同，该请求可继续进入LSU；若不同，Ex1保持该load，记录真实CS，并在后续cycle以真实目标继续。slot1只在另外命中双load或PPB串行条件时replay；单纯CS预测失败不等于无条件清空整条DPU流水线。

Ex2收到MPU的属性和abort，Wr等待data/error/retry并给出commit。返回数据只有在对应slot仍valid、condition pass、无kill/quash、无fault且无retry时，才能写W2/W3或成为后序使用者（consumer）的forwarding源。

#### 5.3.1 推测了什么，没有推测什么

| 机制 | 可提前的内容 | 不允许提前确定的内容 |
| --- | --- | --- |
| 普通load | address/request可在Wr commit前进入LSU。 | RF write enable、架构fault和退休状态必须等晚级确认。 |
| 目标选择 | 用A/base高位预测ITCM、DTCM、AHBP、普通memory或PPB路径。 | 完整地址的真实目标必须由AGU结果复核。 |
| 双load | 先尝试让channel0/channel1并行。 | 低位bank冲突或目标不可并行时，slot1必须replay。 |
| store | Iss可给Store Buffer (STB，存储缓冲区)发“可能有store”的预排空提示，store address也可早送。 | 真正memory write和外部可见副作用必须有Wr commit。 |
| forwarding | 可提前传送生产者（producer）已经产生的base或load data。 | 不允许预测尚未产生的寄存器值；不可用RF旧值代替。 |

这个区分对软件可见副作用很重要。普通normal-memory load可以提前发起，但PPB或device/strongly-ordered访问可能具有读副作用，必须在MPU属性和目标确认后按LSU/PPB串行规则执行，不能把普通cacheable load的推测策略直接用到所有地址。

#### 5.3.2 早期CS预测

早期目标选择的概念算法是：

```text
predicted_target = decode_target(base_A的高地址, TCM/AHBP配置)
full_address      = AGU(base_A, offset_B, add/sub, pre/post-index)
real_target       = decode_target(full_address的高地址, TCM/AHBP配置)
```

预测路径使用A/base的高位，是因为base读取与目标decode可以和AGU加法并行。当offset没有把地址推过ITCM/DTCM/AHBP/PPB窗口边界时，预测和真实目标一致，节省了一条“AGU加法后再选LSU目标”的长组合路径。

重实现必须把TCM size/mask、AHBP size/mask和是否实现纳入`decode_target`，不能只固定检查地址最高3-bit。PPB也是真实目标的一种，但它不使用普通LSU data channel，需要后续串行和独立握手。

#### 5.3.3 Ex1预测失败纠错

当`predicted_target != real_target`时，DPU执行的是局部纠错，而不是架构异常：

1. 在Ex1拉起mispredict stall，保持该slot的完整地址、大小、load/store类型、PC和destination。
2. 把两个channel的real target记录到CS寄存器，后续cycle使用记录值取代早期预测值。
3. 只有纠正后的目标才能随该事务进入后续LSU/PPB上下文；错误候选不得产生RF write、fault commit或store副作用。
4. 若此时还发现PPB与普通LSU不可并行、slot1 PPB RAW hazard或双load bank冲突，再单独replay slot1。

LSM在同一cache line内连续传输时保持已确认CS；当burst跨过需要重新选目标的边界时再复核。这避免同一组multiple transfer每个beat在预测值与真实值之间抖动。

#### 5.3.4 双load的推测并行与slot1 replay

两条load在Iss满足基本双发射条件后，DPU先把它们当成可并行候选。为减少Iss的组合路径，简化早期AGU只快速计算部分地址信息。以下任一条件成立时，slot1不与slot0继续并行，而是replay：

1. 两个load的最终地址bit[2]相同，该组合无法在当前memory data banking中有效并行。
2. 任一load的base需要early forwarding，导致简化早期AGU提供的address bit[2]不能保证正确。
3. 任一load早期预测为PPB，因为PPB不允许和普通LSU transaction这样并行。
4. base来自Wr MAC结果或STREX status等不能进入时间紧张的早期AGU旁路。

replay的行为是：slot0继续，slot1在Ex1被mask，其IQ/skid身份、PC、目的寄存器和访存属性被保留，后续作为slot0重新执行。这不是“两条load都失败”，也不要求清空cache或memory。

#### 5.3.5 commit、flush、kill与fault门控

推测读取的核心是把“request已发出”和“结果可提交”建模成两个独立状态。

| 事件 | DPU/LSU行为 |
| --- | --- |
| Ex1/Ex2中程序顺序靠后的load（younger load）被branch或exception取消 | DPU向LSU发flush，该transaction不再向后续级提供架构valid。 |
| load已到Wr但仍属于推测状态 | DPU可发kill-spec；LSU结合自身kill mask判断哪个内部事务可取消。 |
| condition fail / quash / 更老fault | 不产生load RF write、store commit、exclusive state update或错误路径fault。 |
| LSU abort | 只有当该slot仍是正确路径上最老的可提交指令时，才转为精确异常。 |
| LSU retry | 本次返回不是架构结果，不得写RF或forward；保留上下文后replay。 |
| load正常commit | 数据整理完成且result-valid后可写W2/W3，同时成为受控forwarding源。 |

Store Buffer的Iss提示只用于提前排空一个缓冲slot，它不包含最终store data和commit授权。store address可早于Wr进入LSU，store data通常在C/Ret路径取得，但对memory的真正写入必须等`dpu_lsu_commit_*_wr`类提交条件。因此推测store提示与推测load数据返回不是同一类副作用。

这里的flush/kill表示“取消该指令的架构结果”，不能理解为清空D-cache、TCM或memory，也不保证撤销已经完成的内部cache lookup或bus handshake。取消后普通normal-memory读是否留下不可架构观察的cache/timing状态由LSU/DCU实现决定；DPU边界必须保证的是不写RF、不提交store、不上报错误路径同步fault。对可能具有读副作用的PPB/device访问，则必须使用目标确认、属性检查和串行规则阻止不合法的推测副作用。

#### 5.3.6 PLD与普通推测load的区别

Preload Data (PLD，数据预取提示) 是软件显式写出的cache prefetch hint。它在DPU内部复用load uOP、AGU和LSU请求外形，但不是“一条普通load被CPU偷偷提前执行”。

PLD不写通用寄存器，不走PPB read data语义，不参与普通load的多拍/串行判断。当MPU不允许或目标不适合prefetch时，该hint可被抛弃，不上报普通load的MPU fault。LSU可用内部fake-data-valid类完成信号结束PLD流水事务，但该“data”不得进入RF或forwarding网络。

#### 5.3.7 推测性读取与forwarding的关系

两者是不同机制，但在load的两端相连：

```text
前序生产者（older producer）结果
    → forwarding选中新base
    → load的A操作数
    → 早期CS预测 + AGU完整地址
    → LSU发起推测性读取

LSU返回load data
    → abort/retry/condition/kill/commit门控
    → W2/W3 result-valid
    → forwarding送给后序使用者（consumer）
```

第一条链上，forwarding必须先提供真实base，DPU才能基于该base预测访存目标。如果base的生产者尚未产生数据，load必须interlock，不能用旧base发一个错地址请求。第二条链上，load data即使已物理返回，也只有成为合法result-valid后才可forward。

![推测目标错误后的纠错时序](assets/dpu-speculative-read-timing.svg)

时序图给出一个“无额外下游stall、LSU数据在示意C5返回”的例子：

1. C0上升沿后load进入Iss，A/base已经由RF或forwarding选定。
2. C1上升沿后，早期候选CS和AGU完整地址同时有效；比较发现不相等，因此整个C1保持Ex1上下文并拉起stall。
3. C2上升沿后，已记录的real CS重新驱动正确目标，LSU接受纠正后的事务。
4. C3至C5的数据延迟取决于TCM/cache/外部memory和stall；图中的C5只是示例，不是固定三cycle规格。
5. C5 data-valid时还要检查commit条件。若期间发生branch kill、condition fail、abort或retry，不写RF也不对后续指令forward。

所有同步状态变化都对齐图中上升沿虚线；stall期间信号保持，不得在cycle中间改变slot身份。

#### 5.3.8 重实现必须满足的规则

1. 每个推测访存事务都必须捆绑slot程序顺序（instruction age）、PC、完整地址、target、size/sign、destination、condition、MPU属性和kill/commit状态。
2. request-valid与commit-valid必须分离；早期request不得直接产生RF写、store写或fault上报。
3. CS预测失败必须保持Ex1事务并以real target纠错；纠错不得重复提交或丢失slot1。
4. 双load不可并行时只replay程序顺序靠后的slot1，前序slot0已完成的合法进展不得重做。
5. 任一kill/quash/fault/retry都必须同时屏蔽RF write和forwarding valid；store还要屏蔽memory commit。
6. 应断言“未获得真实base时不发load request”、“CS mismatch时事务不前进”和“没有commit的返回数据不得写RF”。

### 5.4 LSU与MPU时序

![普通load时序](assets/dpu-memory-timing.svg)

Ex1上升沿后地址和request有效，同时向MPU发P0 lookup。下一phase得到P1属性/abort并进入Ex2上下文。LSU在LS1接受地址，数据、abort、retry在LS3对应Wr返回。若任何ready不足，相关流水级保持，波形只能在上升沿边界改变。

两条普通独立访存可使用channel0/channel1并发，但必须满足：地址不要求序列化、不是同一架构指令的特殊多拍、没有exclusive/branch-load冲突、LSU两个通道都可接收且MPU lookup能正确关联。

`dpu_lsu_commit_0/1_wr`只在Wr确认condition pass、无kill/quash且无更高优先级异常时拉高。store address可更早送出，但memory side effect必须受commit约束；load数据即使返回，被kill时也不得写RF。

### 5.5 load数据整理

两个`cm7dpu_swizzle_load`各处理一个返回通道：

1. 根据Ex2保存的地址低2位选择目标byte或halfword。
2. 根据访问大小选择8、16或32-bit。
3. signed load做符号扩展，unsigned load做零扩展。
4. 大端模式交换byte lane；PPB隐式little-endian，不应用普通memory端序交换。
5. PPB load在Wr选择`ppb_dpu_rd_data`，普通load选择LSU LS3 data。
6. 同时产生正常写回、early forwarding、branch target和debug观察所需的不同格式。

load-to-PC使用无错误的整理后32-bit值作为分支目标，并检查T-bit和对齐；因此这类branch通常到Wr才解析。

### 5.6 store数据整理

store源数据通过C口在Ex2/Ret读取。`cm7dpu_swizzle_store`根据Ret地址低位、element size和E-bit形成64-bit写数据；顶层同时产生8-bit write strobe。双通道store或跨边界store必须保证每个byte只写一次。

PPB store地址和提交在Wr，数据也由Wr路径提供；普通LSU store的数据在Ret交付。若store在地址已发送后被异常取消，LSU使用kill/commit区分推测地址和真正副作用。

### 5.7 非对齐与跨界访问

访问是否跨32-bit边界由size和地址低2位判断；doubleword还检查64-bit边界。允许的非对齐访问拆成多个beat，更新address、strobe和data lane；禁止的情况产生UsageFault/unaligned abort，不发架构store副作用。

以下访问必须按架构或配置禁止非对齐：exclusive、部分device/strongly-ordered属性、LDM/STM、双字特殊操作，以及CCR.UNALIGN_TRP要求trap的普通访问。重实现需要在MPU属性返回后再次确认，不能只在AGU按地址判断。

### 5.8 LSM、LSD与中断继续信息

Load/Store Multiple (LSM，多寄存器装载/存储)从16-bit寄存器列表中每cycle选择最多两个最低编号寄存器，形成两个memory beat。列表、next register、first/last、base writeback和是否single保存在Ex1状态中，直到最后一个寄存器完成。

Load/Store Double (LSD，双字装载/存储)使用两个目的或源寄存器；若PPB、边界或资源要求单通道，会拆成两cycle。base只在第一拍更新，两个数据word按端序和地址规则映射。

ICI在本设计中表示可中断多寄存器传输的继续信息。异常打断真实LDM/STM时，DPU记录下一寄存器编号和base修正；异常返回后从剩余列表继续。重实现必须保证已commit的beat不重复、未commit的beat不丢失，并在base-in-list时恢复正确base。

### 5.9 PPB序列化

PPB读取分为address handshake与data handshake；写入也要求ready和commit。PPB寄存器可能有读/写副作用，默认一旦进入不可kill阶段就必须完成，因此DPU阻止年轻指令越过。`ppb_dpu_can_kill`明确允许的事务才可响应branch/exception kill。

MRS/MSR不等同于普通PPB transaction：部分核心系统寄存器直接在DPU/NVIC/FPU状态中读写。无论实现路径如何，软件观察到的顺序必须与barrier和异常边界一致。

### 5.10 barrier与exclusive

| 指令 | DPU规则 |
| --- | --- |
| Data Memory Barrier (DMB，数据存储屏障) | 后续memory access不能越过屏障；等待LSU确认前序顺序约束。 |
| Data Synchronization Barrier (DSB，数据同步屏障) | 等待前序显式memory access和相关系统副作用完成，再允许后续指令。 |
| Instruction Synchronization Barrier (ISB，指令同步屏障) | 在Wr提交后force/refetch PFU，并通知ICU；清除旧前端上下文。 |
| LDREX/STREX | 通过LSU exclusive monitor；STREX状态结果写RF，store只在monitor成功且提交时发生。 |
| CLREX | 清除exclusive monitor，不产生普通memory data。 |

exception entry通过`dpu_lsu_excpt_clrex`清除exclusive状态。barrier、exclusive和普通双发射load/store的配对必须按Iss限制处理，不得依赖LSU最终拒绝来修正顺序。

### 5.11 错误与重试

MPU abort、LSU synchronous abort、PPB error和unaligned trap随对应slot进入Wr。若指令被较老branch quash，该错误也被quash；若错误属于最老可提交指令，则阻止RF/memory commit并启动精确异常。

LSU retry表示本次尝试没有形成架构结果。DPU保存指令上下文并replay，第一次返回的数据、write enable、BTAC维护和trace valid均不得提交。异步bus error由program-flow单元在合法边界转成BusFault/HardFault。

## 6. 程序流、分支解析与BTAC维护

本章描述DPU的PC维护，以及BTAC预测的解析和反馈。

### 6.1 分支解析层次

![分支解析与恢复](assets/dpu-branch-resolution.svg)

`cm7dpu_prog_flow`维护PC、prediction context和force。分支并非固定在一个stage解析：直接分支在条件标志已稳定时可在Iss解析；普通寄存器/ALU分支通常在Ex2；load-to-PC、异常返回和部分ISB在Wr。越早解析只减少错误路径长度，不改变提交顺序。

### 6.2 PC表示

DPU内部PC主要保存`[31:1]`，bit0用于Thumb状态检查而不是普通地址加法。`pc_s_ex1`和`aj_s_ex1`组合得到slot0 PC；slot1 PC在其前面加slot0指令长度，若slot0是预测taken分支则使用BTAC target关系。slot1 replay时使用保存的`pc_r_ex1`，避免因当前IQ变化重算错误PC。

对软件读取PC的指令，返回值要按Thumb架构定义包含pipeline offset和对齐，而不是直接暴露内部fetch地址。branch target、fall-through和refetch address分别计算，不能用一个加法结果在所有情况复用。

### 6.3 Iss早期解析

#### 6.3.1 条件是否可判断

`can_chk`成立条件为：无条件指令，或条件指令所需NZCV已经稳定且不是必须读取通用寄存器结果的CBZ/CBNZ。稳定表示Ex1/Ex2不存在更老pending flag writer；Wr准备提交的flag可以forward。

#### 6.3.2 静态预测

BTAC miss时，direct backward branch静态预测taken，direct forward branch预测not-taken；indirect branch miss预测not-taken。该规则只决定前端方向，实际condition仍需按NZCV解析。

#### 6.3.3 Iss force条件

直接分支在可判断时比较实际方向和BTAC方向；实际taken还比较真实offset和BTAC offset。BTAC miss且实际taken也要force到target。条件尚不可判断且BTAC miss的backward direct branch，为实现静态taken会先force到目标并把pending状态带到后级。

BX LR只有LR没有in-flight writer、LR bit0合法且condition可判断时才能早期解析。其他indirect branch保留到Ex2/Wr。

### 6.4 Ex2与Wr解析

Ex2使用DP0/DP1结果形成寄存器branch target、CBZ/CBNZ方向和ALU-to-PC结果。prediction pending时比较`predicted direction/target`与`actual direction/target`；方向错误总要force，目标错误只在实际taken时有意义。

Wr处理load-to-PC数据、exception return、ISB和在Ex2仍未完成的情况。load结果只有在LSU返回、swizzle和error检查后才能成为PC。异常返回还要恢复T-bit、IPSR、mode和SPSEL，force PC只是整个原子状态恢复的一部分。

### 6.5 force与清除

force address选择实际taken target或not-taken fall-through。更老stage的force必须优先于更年轻stage：Wr/retirement相关重定向高于Ex2，Ex2高于Iss。slot0高于同级slot1，因为slot0程序顺序更老。

force产生后：

1. PFU取消旧fetch、清IQ/FIFO并从正确PC取指。
2. DPU kill force点之前的年轻stage，quash同cycle位于branch之后的slot1。
3. branch本身和更老指令保留并正常提交。
4. 已发出但未commit的LSU/PPB/FPU副作用被kill/fail。
5. BTAC只维护相关entry，不整体清空。

![Ex2发现分支预测错误的时序](assets/dpu-branch-mispredict-timing.svg)

图中branch B在C3的Ex2确认预测错误，C3到C4边界产生force/flush。B继续进入Wr并用实际结果维护BTAC；B之后的Y在C4被kill。正确路径T只能在force后重新进入PFU和De，不能把Y的数据位改名后继续使用。图中所有信号边沿与cycle边界对齐。

### 6.6 BTAC命中合法性

PFU传来的4-bit hit按两个slot各两个半字表示。DPU根据指令是16-bit还是32-bit选择真正属于指令末半字的hit。以下情况视为非法hit并要求refetch/invalidate：

1. hit落在32-bit指令第一半字，而不是可关联的指令边界。
2. hit关联到译码后不是branch的指令。
3. predicted taken offset发生表示范围下溢或元数据不一致。

非法hit优先于同entry错误，因为前端指令/元数据关联本身已经不可信。

### 6.7 BTAC维护

| 操作 | 触发 | 输出 |
| --- | --- | --- |
| allocate | 真实branch在Wr有效、没有可更新hit，且该doubleword没有冲突hit。 | branch address、actual offset、actual taken。 |
| update | branch命中BTAC并到Wr；无论预测正确与否都可更新方向历史，目标错误时更新offset。 | 原entry index、actual taken、offset。 |
| invalidate | 非法hit或需要清理错误entry。 | 当前/相邻lookup对应invalidate bit和index。 |

maintenance只对真实指令进行，microcode不分配BTAC。异常kill可以保留已经得到的有效branch学习信息，但branch kill、replay重复尝试和错误hit不能重复allocate/update。

### 6.8 BNE实例

Branch if Not Equal (BNE，不相等则跳转)在Z=0时taken。若更老CMP正在Wr提交Z=1，且Ex1/Ex2无其他pending flag writer，Iss通过Wr-to-Iss forwarding得到Z=1，判断BNE not-taken。若BTAC预测taken，则Iss产生fall-through force、quash更年轻slot并在Wr更新BTAC为not-taken。

如果CMP紧邻BNE，BNE在Iss时CMP仍在Ex1，`can_chk=0`。BNE携带prediction context前进，在Ex2使用已经产生的NZCV复核。这里没有“在Iss读取未来Z”的行为。

### 6.9 分支不变量

1. 每cycle最多发射一条branch，branch可位于slot0或slot1。
2. prediction pending、direction、target和BTAC index必须原子跨级。
3. target比较只在actual taken时影响mispredict。
4. replayed branch不能第二次force或第二次BTAC update。
5. slot0 branch重定向时，同cycle slot1一定是更年轻路径，必须quash。
6. ISB即使PC数值不变也需要front-end refetch，以建立新的指令同步上下文。

## 7. 异常、睡眠、Debug与Trace

本章描述DPU与NVIC、debug和trace的协作。

### 7.1 异常协作数据流

![异常进入与返回数据流](assets/dpu-exception-flow.svg)

异常由`cm7dpu_prog_flow`选择精确边界，由`cm7dpu_front_end`注入stack/unstack微码，由LSU执行frame memory access，由PFU读取vector。NVIC决定哪个异常应被invoke；DPU负责让被选异常看起来发生在一条完整架构指令之后、下一条指令之前。

### 7.2 异常主状态机

![异常主状态机](assets/dpu-exception-fsm.svg)

#### 7.2.1 状态详细说明

| 状态 | 驻留行为 | 主要退出条件 |
| --- | --- | --- |
| `ST_RESET` | 等待reset vector/MSP路径有效，屏蔽普通执行；可处理reset vector fault/lockup。 | reset entry条件完成后启动entry并离开。 |
| `ST_IDLE` | 正常分支、退休和异常请求观察；可开始entry、return、sleep或halt。 | interrupt/fault→ENT_WT；EXC_RETURN→RET_WT；halt→HLT_WT。 |
| `ST_ENT_WT` | 请求PFU vector，清除年轻指令，等待Wr可kill边界和前端接受entry微码。 | entry微码开始→ENT_ST；tail-chain可直接完成状态切换。 |
| `ST_ENT_ST` | stacking微码在流水中；设置LR EXC_RETURN、mode、IPSR、SP和FP上下文状态。 | frame与vector都完成→IDLE；新高优先级到达可tail-chain；派生fault可重启entry。 |
| `ST_RET_WT` | unstack/return微码执行，恢复PC/xPSR/寄存器和mode；期间可被新异常抢占。 | return完成→IDLE；sleep-on-exit→SLP_ST；新异常→ENT_ST。 |
| `ST_LZY_WT` | 当前浮点指令被quash，等待lazy FP frame保存完成，然后重试原指令。 | lazy序列完成→先前entry/normal流程。 |
| `ST_SLP_ST` | sleep-on-exit已选择，不再执行线程指令；等待wake、interrupt、halt或step。 | 中断→ENT_ST；普通wake→RET_WT。 |
| `ST_HLT_WT` | 停止取新指令并清空可清流水，等待不可kill操作和trace完成。 | halt安全→HALTED；期间entry/return优先处理。 |
| `ST_HALTED` | debug halt稳定态，允许寄存器和AHBD访问。 | halt请求释放→生成force到`pc_ret`并回IDLE。 |

异常状态机允许tail-chaining：当前handler返回时若已有更高优先级异常，不必先恢复线程frame再重新压栈，而是更新异常状态并直接取新handler。late arrival允许entry过程中更高优先级异常替换原目标，但已进行的stacking仍保持一致。

### 7.3 精确异常与kill优先级

异常进入不能破坏较老不可kill事务。`cm7dpu_prog_flow`先判断Wr是否处于一条多cycle指令、PPB不可kill数据相位、LSM原子微码或FPU out-of-order操作；能kill时级联清除Wr→Ex2→Ex1→Iss，不能kill时等待其形成指令边界。

同步fault属于当前指令，必须阻止该指令的RF/memory状态提交；异步interrupt发生在前一条已提交指令之后。branch和exception同时发生时按指令年龄选择：较老branch先确定正确路径；已经位于wrong path的fault不能被报告。

### 7.4 异常frame

SP、LR、xPSR、EXC_RETURN与lazy的基础定义和完整数据布局见2.5.1节。本节从程序流状态机的角度补充其执行规则。

基本整数frame保存R0-R3、R12、被打断程序原来的LR、Return PC和xPSR，共8个word、32 bytes。异常进入根据当前SP选择MSP或PSP，并根据stack alignment配置调整。旧LR已保存在frame中，DPU随后把EXC_RETURN写入handler可见的LR，用其位域记录返回Thread/Handler mode、MSP/PSP和是否存在FP frame。

FPU存在且FPCA有效时有两种策略：

1. full stacking：先保存浮点frame，再保存整数frame。
2. lazy stacking：先为18个word、72 bytes的FP frame预留空间并记录FPCAR，只立即写入整数frame；handler首次真正执行浮点指令时再保存S0-S15与FPSCR。

lazy触发时当前浮点指令在Wr被quash，微码完成后replay。LSPACT在部分entry完成后置位，在lazy保存或完整return完成后清除。

### 7.5 同步事件与lockup

同步事件状态机把SVC、BKPT、debug step、prefetch/data fault、NOCP、division-by-zero和vector fault编码成统一等待状态，stall退休直到NVIC/debug给出处理方向。事件被更老branch quash时必须放弃。

lockup用于无法再通过正常异常升级恢复的情况，例如HardFault/NMI处理期间再次发生不可处理fault、reset/vector严重错误。lockup状态保持CPU停止正常退休，可由reset或debug控制离开；必要时force PC为全1观察值。实现必须区分可见lockup和内部为处理vector竞态暂存的pending lockup。

![同步事件状态机](assets/dpu-sync-fsm.svg)

同步事件图把`SYNC_IDLE`放在中心，四类等待状态分布在四角。进入边表示Wr检测到的事件类型，返回边表示外部NVIC/debug确认；各边与状态框文字分离。

同步事件状态机的每个状态如下：

| 状态 | 驻留行为与退出 |
| --- | --- |
| `SYNC_IDLE` | 正常观察Wr；vector fault优先，其次普通fault/SVC/monitor、debug事件、invalid-PC和escalated lockup。 |
| `SYNC_INT` | stall Wr并等待NVIC fault acknowledge；收到后回IDLE。 |
| `SYNC_DBG` | stall Wr并等待debug halt开始或新的interrupt invoke；任一发生后回IDLE。 |
| `SYNC_VEC` | vector fault专用等待；NVIC确认新的处理方向后回IDLE。 |
| `SYNC_LKP` | 一cycle内部脉冲，把升级失败传给lockup状态机，下一cycle回IDLE。 |

![lockup状态机](assets/dpu-lockup-fsm.svg)

Lockup图按普通指令、entry push、vector和return四种来源分层。实线进入`LKP_INST`表示lockup成为架构可见状态，虚线返回IDLE表示新异常抵消了尚未最终成立的pending lockup。

Lockup状态机的每个状态如下：

| 状态 | 驻留行为与退出 |
| --- | --- |
| `LKP_IDLE` | 无lockup；按fault发生在普通指令、entry push、vector或return选择目标状态。 |
| `LKP_INST` | 架构lockup有效并保持；成功退休边界、halt完成或新interrupt invoke可清除。 |
| `LKP_PUSH` | entry stacking中发生lockup，等待entry commit；若commit时Wr仍stall，转ENTP，否则转INST。 |
| `LKP_ENTP` | entry已commit但Wr仍stall，防止最后一拍微码被错误kill；stall释放后转INST。 |
| `LKP_VECT` | vector lockup pending；new arrival可取消，否则entry完成后转INST。 |
| `LKP_EXIT` | exception return中发生lockup；新interrupt可取消，否则return commit后转INST。 |

### 7.6 sleep状态机

![sleep状态机](assets/dpu-sleep-fsm.svg)

| 状态 | 行为 |
| --- | --- |
| `SLP_IDLE` | 正常运行，等待已提交WFI/WFE或forced sleep请求。 |
| `SLP_WFX_K` | 首cycle发出pipe flush和PFU stop；若此时已有leave-sleep条件则直接回IDLE。 |
| `SLP_WFX_P` | 等待PFU、LSU、PPB和FPU都静止；收到wake则转A，否则静止后转S。 |
| `SLP_WFX_S` | normal sleep；wake转A，forced-sleep请求转F。 |
| `SLP_WFX_F` | forced sleep；wake/invoke先转W，forced请求撤销且无wake则回S。 |
| `SLP_WFX_W` | forced sleep期间已收到wake；等forced请求撤销后转A。 |
| `SLP_WFX_A` | wake-up flush；等待AHBD空闲和Wr可前进，再回IDLE。 |

Wait For Interrupt (WFI，等待中断)由可服务interrupt、debug或event条件唤醒；Wait For Event (WFE，等待事件)还使用event register。SEV或外部RXEV置event，WFE消费event时清除。所有wake都通过flush/force恢复，而不是让sleep前已经取入的年轻指令直接继续。

### 7.7 debug

debug可请求single-step、halt、读写整数/FPU寄存器和通过AHBD访问memory。single-step只允许一条真实指令形成退休事件；内部microcode和AHBD不计作被步进的程序指令，但必须在该指令需要时完成。

halt进入等待不可kill事务完成，随后`ST_HALTED`允许debug RF访问。debug写PC、xPSR或CONTROL通过`cm7dpu_prog_flow`更新并force前端；debug写普通RF使用异常共享写口。protected instruction属性会屏蔽不允许的halt观察。

### 7.8 ETM和DWT

`cm7dpu_etm_intf`只观察成功退休或被明确取消的事件。它接收每slot instruction address/size/condition、load/store address/size/data、exception entry/exit、LSM index和restart。ETM输出编码控制流；DWT输出指令/数据valid、cancel、exception number和protection。

trace必须反映架构顺序而不是执行完成顺序：

1. 被kill/quash/replay第一次尝试的指令不能报成功退休。
2. LSM每个已commit beat可产生数据事件，但整条指令只在last形成指令退休边界。
3. branch slot1地址要使用保存的真实PC，不能使用force后的新PC。
4. tail-chain、lazy stacking和reset entry要产生对应exception function，而不是伪装成普通branch。

### 7.9 异常验证场景

1. 普通IRQ打断两条独立ALU之间，验证只保存下一PC。
2. load在Wr abort，验证目的RF不写且fault PC指向load。
3. branch wrong path含fault，验证fault被quash。
4. LDM中途被中断并返回，验证已完成寄存器不重复、ICI继续正确。
5. lazy FP entry后handler首次浮点指令，验证原指令quash、保存、replay一次。
6. return期间late arrival，验证tail-chain不错误恢复线程。
7. WFE已有event，验证不真正停钟而消费event继续。
8. PPB不可kill事务与halt同时发生，验证先完成事务再HALTED。

## 8. 重实现规则与验证计划

本章汇总DPU的可实现接口、优先级、reset和验证完成标准。

### 8.1 推荐实现分区

重实现可以改变内部文件数量，但应保持以下责任边界，避免把异常、旁路和访存提交混成无法验证的组合块。

| 建议分区 | 应包含的行为 | 对应原RTL |
| --- | --- | --- |
| `dpu_frontend` | 三源仲裁、predecode、四项IQ、full/small decode、微码注入。 | `cm7dpu_front_end/predec/iq/dec` |
| `dpu_issue` | pointer映射、RAW/WAW/resource interlock、双发射配对、replay控制。 | `cm7dpu` Iss/interlock逻辑 |
| `dpu_regfile_bypass` | MSP/PSP映射、RF多端口、Ex2/Wr/load/MAC/FPU旁路。 | `cm7dpu_rf`和顶层forwarding |
| `dpu_int_execute` | DP0、DP1、shift/bitfield/SIMD、MAC、DIV、NZCV候选。 | `cm7dpu_dp0/dp1/mac/div` |
| `dpu_memory` | 双AGU、目标decode、LSU/MPU/PPB握手、swizzle、LSM/LSD/ICI。 | AGU、swizzle和顶层LS控制 |
| `dpu_program_flow` | PC、branch prediction pipeline、force、BTAC维护。 | `cm7dpu_prog_flow` branch部分 |
| `dpu_exception` | exception/sleep/sync/lockup状态、架构系统状态和NVIC接口。 | `cm7dpu_prog_flow` exception部分 |
| `dpu_commit_trace` | 四写口仲裁、kill/quash最终门控、Ret、ETM/DWT事件。 | `cm7dpu` Wr/Ret与`cm7dpu_etm_intf` |

分区之间建议传递结构化bundle，而不是重新使用原RTL数百根缩写wire。至少定义`issue_slot_t`、`execute_slot_t`、`memory_txn_t`、`branch_ctx_t`、`commit_slot_t`，每个bundle都包含valid、instruction identity、slot age、first/last、killability和error。

### 8.2 顶层接口规则

#### 8.2.1 PFU

| 方向 | 信息 | 规则 |
| --- | --- | --- |
| PFU→DPU | 两条instruction、valid、T32、error/code、protection、BTAC hit/taken/offset/index | valid期间关联信息原子；DPU未pop不得丢失或换序。 |
| DPU→PFU | pop[1:0] | `01`消费slot0，`11`消费两条；不能只消费slot1。 |
| DPU→PFU | force valid/address、stop、interrupt vector request | force只脉冲一次；地址在valid周期稳定。 |
| DPU→BTAC | allocate/update/invalidate及address/offset/taken/index | 只对合法真实branch提交一次。 |

#### 8.2.2 LSU/MPU/PPB

LSU两个channel各输出Ex1地址、request/chip-select、store、size、strobe、first和privilege；Wr输出commit，Ret输出store data。MPU P0接收`address[31:5]`、write和privilege，P1返回abort与6-bit attributes。PPB使用独立read-address/read-data/write握手；不可kill时DPU必须等待。

#### 8.2.3 FPU

DPU与FPU各自有Ex1/Ex2/Wr stall和valid。任何一侧stall都必须保持两个pipeline pointer一致；kill/fail分别表示删除整个浮点uOP或只取消结果。FPU out-of-order-in-flight时，exception/halt必须等待或按协议kill，不能直接切换context。

#### 8.2.4 NVIC、debug和trace

NVIC提供invoke、new-arrival、next ISR、wakeup、abandon和fault acknowledge；DPU输出entry/exit/return、IPSR、mask、fault status和active update。debug RF访问只在halt/允许窗口接受。ETM/DWT输出只基于commit/retire视图。

### 8.3 全局优先级

同cycle多个控制事件必须按指令年龄和架构强制性排序。建议实现为显式priority encoder并逐项assert。

| 高到低 | 事件 | 说明 |
| --- | --- | --- |
| 1 | reset / reset vector lockup | 清除所有valid和控制状态，禁止普通提交。 |
| 2 | 已确定的更老Wr异常/exception return/不可恢复fault | 决定架构状态和正确PC。 |
| 3 | Wr branch、load-to-PC、ISB、replay force | 高于更年轻Ex2/Iss重定向。 |
| 4 | Ex2 branch mispredict | kill Ex1/Iss和同级年轻slot。 |
| 5 | Iss branch/refetch | 清前端和slot1，不影响更老stage。 |
| 6 | stall | 在没有更高优先级kill时保持stage。 |
| 7 | 普通advance/writeback | 只对未kill、condition pass的slot生效。 |

stall与kill同时发生时，kill必须留下可观察的invalid结果；不能因stall保持旧valid而在下一cycle复活。对不可kill PPB等事务，异常状态机应等待，而不是强行违反接口规则。

### 8.4 reset规则

`reset_n`为低时至少清除：IQ valid、各stage valid、branch pending、divider state、microcode/exception/sleep/sync/lockup状态、architectural mask/control的reset-defined位、LSU/PPB commit pending和trace valid。

RAR配置为0时，纯数据寄存器可不物理reset，例如旧操作数、部分积和FIFO data；但它们必须被valid隔离。RAR为1时原RTL还复位这些数据寄存器，以支持验证/安全配置。重实现可采用不同门控，只要reset后任何未初始化数据都不可影响输出。

reset release后PFU先提供MSP和reset handler vector。`cm7dpu_prog_flow`通过异常RF写口设置MSP，建立Thread mode、privileged、Thumb状态和IPSR=0，再允许handler指令进入正常流水。reset handler地址不是DPU从普通RF中读取。

### 8.5 关键算法伪代码

#### 8.5.1 发射

```text
if reset_or_flush_or_stall_iss or not head0.valid:
    issue = 0
else if not slot0_sources_ready or slot0_resource_busy:
    issue = 0
else:
    issue.slot0 = 1
    if head1.valid and pair_allowed(slot0, slot1)
       and slot1_sources_ready and slot1_resource_ready:
        issue.slot1 = 1
    else:
        issue.slot1 = 0
```

`pair_allowed`必须包含slot不对称、同cycle依赖、两branch、MAC/DIV/LSM/system/FPU/LSU组合和ACTLR配置，不能只检查两个uOP类别不同。

#### 8.5.2 源操作数

```text
最近前序生产者 = 查找最近的前序写者(源寄存器)
if 最近前序生产者不存在:
    操作数 = 寄存器堆[源寄存器]
else if 最近前序生产者.本stage结果有效
        and 最近前序生产者.未被kill:
    操作数 = 最近前序生产者.旁路数据
else:
    互锁(interlock) = 1
```

#### 8.5.3 commit

```text
slot_commit = stage_valid
              and condition_pass
              and not kill
              and not quash
              and not retry
              and not synchronous_error

RF_write      = slot_commit and decoded_rf_write
flag_update   = slot_commit and decoded_flag_write
memory_commit = slot_commit and decoded_memory_side_effect
trace_retire  = slot_commit and instruction_last_uop
```

#### 8.5.4 分支恢复

```text
actual_taken = evaluate_condition(latest_valid_nzcv_or_register)
actual_pc    = actual_taken ? actual_target : fall_through
mispredict   = predicted_taken != actual_taken
               or (actual_taken and predicted_target != actual_target)

if mispredict:
    select oldest force request
    kill all younger slots/stages
    flush PFU and front-end IQ
    preserve branch and older instructions
```

### 8.6 多cycle指令原子性

DIV、LSM、LSD、exception microcode和部分FPU操作会跨多个cycle或uOP。每条需要以下身份字段：

| 字段 | 用途 |
| --- | --- |
| `first` | 捕获base、原始PC、condition和初始列表；只执行一次。 |
| `last` | 形成架构指令退休边界、IT advance和single-step事件。 |
| `instruction_id` | 防止replay或拆拍被trace/BTAC当作新指令。 |
| `killable` | 标明该拍能否被exception/branch取消。 |
| `committed_beats` | LSM/PPB等恢复时区分已发生与未发生副作用。 |

中间uOP可以写局部结果，但异常观察必须等到合法边界；已commit memory beat则通过ICI保证返回后不重复。

### 8.7 源码缺口与实现决策

| 缺口 | 可确定部分 | 重实现决策 |
| --- | --- | --- |
| `cm7dpu_rf.v`为空 | 读写端口、stage、MSP/PSP映射、写口使用和旁路关系。 | 实现行为多端口RF；同址读写通过外部forward得到新值，RF内部可read-first。 |
| `cm7dpu_alu_shift.v`为空 | 输入/输出、Ex1位置、carry valid和RRX语义。 | 按Armv7-M shift边界表实现，并建立随机reference model。 |
| `cm7dpu_alu_simd_sat.v`为空 | DP0控制和Wr Q更新位置。 | 按每lane signed/unsigned saturation实现。 |
| full T16 decoder为空 | predecoder字段、后级端口及其他decoder模式。 | 从Armv7-M encoding表生成decoder，禁止手工散落case。 |
| full FPU decoder为空 | FPU control bus格式和small decoder行为。 | 以实现的FPU指令集配置生成；无FPU配置统一NOCP。 |

### 8.8 验证矩阵

#### 8.8.1 单元级

| 单元 | 必测内容 |
| --- | --- |
| IQ | 所有push/pop/stall/flush/replay组合，顺序和容量不变量。 |
| decoder | 每个Thumb encoding的合法/非法、寄存器指针、立即数、uOP和flag控制。 |
| RF/bypass | 每个stage到每个源的RAW，slot0→slot1，kill后的forward屏蔽。 |
| DP0/DP1 | 算术边界、carry/overflow、shift 0/32/>32、bitfield、REV、CLZ、SIMD/saturation。 |
| MAC | signed/unsigned、long、accumulate、round、Q/N/Z。 |
| DIV | 0、1、最大值、负数、INT_MIN/-1、divide-by-zero、每个state kill。 |
| memory | 地址目标、端序、非对齐、跨32/64、PPB、MPU abort、LSU retry。 |
| program flow | direct/indirect/load branch在Iss/Ex2/Wr的所有预测组合和force优先级。 |
| exception | entry/return、tail-chain、late arrival、lazy FP、sleep、halt、lockup。 |

#### 8.8.2 系统级指令序列

1. 两条独立ALU持续双发射，验证每cycle两条退休。
2. slot0生产、slot1消费的允许和禁止组合。
3. load-use、MAC-use、VMRS-use、flag-to-Bcc的精确气泡数。
4. branch预测taken/not-taken/target错误，wrong-path包含store和fault。
5. 双通道load/store和其中一个channel abort/retry。
6. LDM/STM在每个beat被IRQ打断并返回。
7. PPB不可kill事务叠加branch、IRQ和halt。
8. lazy FP保存期间LSU stall、fault和更高优先级exception。

#### 8.8.3 必备assertion

```text
slot1_commit -> slot0_same_group_valid_or_already_committed
stall_stage -> stable(stage_bundle)
kill_or_quash -> !rf_write && !memory_commit && !flag_update
replay_first_attempt -> !architectural_side_effect
two_branches_issued == false
div_active && !done -> stall_ex2
btac_update -> real_branch && instruction_last && !duplicate_replay
ppb_un killable_inflight -> no_younger_commit
```

### 8.9 完成标准

新DPU只有在以下条件同时满足时才能视为行为兼容：

1. 全部实现指令产生正确寄存器、flag、memory和异常结果。
2. 双发射不会改变单发射参考模型的架构顺序。
3. 任意stall/kill/quash/replay组合不重复或遗漏副作用。
4. PFU、LSU、MPU、PPB、FPU、NVIC和trace接口在backpressure下稳定。
5. 分支错误路径的store/fault/FPU写全部被取消，分支本身正常学习BTAC。
6. 异常entry/return、tail-chain、lazy stacking和中断LSM可恢复。
7. 所有状态机都有非法状态恢复或assertion，reset后不会使用未初始化data。
