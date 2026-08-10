# Agent Tool-使用教训（kexvim 项目调试）

## search_files 对大文件不完整

`search_files` 用 ripgrep，本身是全文搜索。但工具内部有 `_DEFAULT_MAX_READ_CHARS = 100_000` 的限制，且 `head -n` 限制输出行数。

**后果：** 当 Main.ts 超过 42KB/900+ 行时，对后半段（`main()` 函数、`import("node:worker_threads")`、`SIGTERM` 等）的搜索可能返回零结果，**工具不提示"文件过大/结果可能不完整"**。

### 交叉验证方法

当搜索敏感内容（如确认某个符号"不存在"）时：

1. `wc -l <file>` 检查文件行数，>300 行高度警惕
2. `grep -n "<pattern>" <file>` 在 terminal 里直接搜（绕过 search_files）
3. `read_file` 从可疑位置开始读，直接确认

### 正则转义

`search_files` 默认 pattern 是 regex。搜索字面文本时注意转义：
- `main()` → `main\(\)` 
- `import("node:worker_threads")` → 用 `grep -F` 或转义括号
- 模糊匹配用 `read_file` 读关键部分替代

### 适用场景

- 确认某个类/函数"是否存在"时
- Agent 报告"没找到"但直觉上应该存在时
- 在 200+ 行的核心文件中搜索时
