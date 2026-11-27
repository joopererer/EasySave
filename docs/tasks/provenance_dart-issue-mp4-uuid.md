# Issue Draft: MP4 `uuid` XMP box decoding includes the 16-byte UUID prefix

## 现象（Symptom）
当 `provenance_dart` 读取并更新已包含 Adobe XMP `uuid` box（UUID = `BE 7A CF CB 97 A9 42 E8 9C 71 99 94 91 E3 AF AC`）的 MP4 文件时，提取出的 XMP 文本开头包含一段乱码及 `U+FFFD`（`EF BF BD`）替换字符。

以 EasySave 黄金样本 `spec/fixtures/provenance_golden/mp4_2_xmp_uuid/golden_xmp.xml` 为例，文件前 32 字节（hex）如下：
```text
00000000: EF BF BD 7A EF BF BD CB 97 EF BF BD 42 EF BF BD  ...z.......B...
00000010: 71 EF BF BD EF BF BD EF BF BD E3 AF AC 3C 3F 78  q............<?x
00000020: 70 61 63 6B 65 74 20 ...                         packet ...
```
可见紧邻 `<?xpacket` 之前的部分，正是由 16 字节 XMP UUID `BE 7A CF CB 97 A9 42 E8 9C 71 99 94 91 E3 AF AC` 被按 `utf8.decode(..., allowMalformed: true)` 解码后的产物（非合法 UTF-8 字节序列被替换为 `EF BF BD`，即 `U+FFFD`；部分字节如 `7A` -> `z`、`CB 97` -> `˗`、`42` -> `B`、`71` -> `q`、`E3 AF AC` -> `㯬` 恰好落入可解码字节序列）。

当后续再次嵌入 XMP 时，这段前导乱码会被保留并重新写回新的 `uuid` box 的 XML payload 中，导致每次重写都在 `<?xpacket` 前携带乱码字节。

## 最小复现（Minimal Reproduction）
1. 准备一个已含标准 MP4 XMP `uuid` box 的输入文件（Box 结构为 `[4B size]["uuid"][16B BE7ACFCB97A942E89C71999491E3AFAC][UTF-8 XMP XML]`，例如 `spec/fixtures/provenance_golden/mp4_2_xmp_uuid/input.mp4`）。
2. 调用 `MetadataService.embedProvenance(filePath: ..., provenance: ...)` 或读取该 MP4 的 XMP。
3. 读取输出 MP4 中新写入的 `uuid` box 的 XML payload（跳过新 box 的 8 字节头 + 16 字节 UUID 后）。
4. 实际结果：payload 开头不是 `<?xpacket`，而是 `z˗Bq㯬<?xpacket...`（含 `U+FFFD`）。
5. 预期结果：读取旧 `uuid` box 时应跳过 16 字节 UUID，payload 严格从 `<?xpacket` 开始。

## 建议修法（Suggested Fix）
在 `provenance_dart` 的 MP4 XMP 读取逻辑（`xmp_mp4.dart`）中：
1. 判断 `uuid` box 是否为 XMP box 时，在读取完 `box header`（8 字节或 16 字节 large size）后的 16 字节作为 `uuid` 匹配 `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`。
2. 读取 XML payload 时，起始偏移量必须为 `dataStart + 16`（跳过 16 字节 UUID），长度至少为 `dataStop - (dataStart + 16)`，再做 UTF-8 解码。
3. 同时建议对解码后的 XML 校验或定位 `<?xpacket` / `<x:xmpmeta`，避免历史脏数据继续传播。

