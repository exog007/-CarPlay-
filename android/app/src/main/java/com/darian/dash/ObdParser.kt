package com.darian.dash

/**
 * OBD2 响应解析
 *
 * 从 iOS 版 ObdProtocol.swift 移植。
 * 关键点：
 *   ① BLE 分包会把 CAN 头和数据粘在一起（如 7E8064100BE3FA817）
 *   ② 要能跳过 3 位 CAN 头（7E0~7EF / 7DF）
 *   ③ 位图解析（0100/0120/0140）要能处理多个 ECU 的响应
 */
object ObdParser {

    /** 把 ELM327 的文本响应转成字节数组 */
    fun toBytes(raw: String): ByteArray? {
        val cleaned = raw
            .replace(">", " ")
            .replace("\r", " ")
            .replace("\n", " ")
            .uppercase()

        if (cleaned.contains("NO DATA") || cleaned.contains("UNABLE TO CONNECT")) return null
        if (cleaned.contains("OK") && !cleaned.contains("41")) return null

        val out = ArrayList<Byte>()

        for (word in cleaned.split(" ").filter { it.isNotEmpty() }) {
            if (!word.all { it in "0123456789ABCDEF" }) continue

            when (word.length) {
                3 -> continue              // 独立 CAN 头
                2 -> word.toIntOrNull(16)?.let { out.add(it.toByte()) }
                1 -> continue
                else -> {
                    // 长串：逐字符扫描，识别并跳过 3 位 CAN 头
                    var i = 0
                    while (i < word.length) {
                        // 优先匹配 3 位 CAN 头（7E0~7EF / 7DF）
                        if (word[i] == '7' && i + 3 <= word.length) {
                            val head = word.substring(i, i + 3)
                            val hv = head.toIntOrNull(16)
                            if (hv != null && ((hv in 0x7E0..0x7EF) || hv == 0x7DF)) {
                                i += 3
                                continue
                            }
                        }
                        if (i + 2 <= word.length) {
                            word.substring(i, i + 2).toIntOrNull(16)?.let { out.add(it.toByte()) }
                            i += 2
                        } else {
                            i++
                        }
                    }
                }
            }
        }
        return if (out.isEmpty()) null else out.toByteArray()
    }

    /**
     * 从响应里找出某个 PID 的数据
     *
     * 响应形如：41 0C 1A F8
     * 返回 [1A, F8]
     */
    fun extractValue(bytes: ByteArray, pidByte: Int, byteCount: Int): IntArray? {
        var i = 0
        while (i + 1 < bytes.size) {
            val a = bytes[i].toInt() and 0xFF
            val b = bytes[i + 1].toInt() and 0xFF
            if (a == 0x41 && b == pidByte) {
                val start = i + 2
                if (start + byteCount <= bytes.size) {
                    val r = IntArray(byteCount)
                    for (k in 0 until byteCount) {
                        r[k] = bytes[start + k].toInt() and 0xFF
                    }
                    // 全 0 通常无效（车速除外）
                    if (r.all { it == 0 } && pidByte != 0x0D) return null
                    return r
                }
                return null
            }
            i++
        }
        return null
    }

    /** 解析某条 PID 的值 */
    fun value(bytes: ByteArray, def: PidDef): Double? {
        val pidByte = def.code.substring(2).toIntOrNull(16) ?: return null
        val data = extractValue(bytes, pidByte, def.bytes) ?: return null
        return def.formula(data)
    }

    /**
     * 解析位图，得到车支持哪些 PID
     *
     * 响应：41 00 BE 3F A8 13
     *   每个 41 XX 后面 4 字节是位图
     */
    fun parseSupportedCodes(bytes: ByteArray): Set<String> {
        val out = HashSet<String>()
        var i = 0
        while (i + 5 < bytes.size) {
            if ((bytes[i].toInt() and 0xFF) != 0x41) { i++; continue }
            val base = bytes[i + 1].toInt() and 0xFF
            for (bi in 0 until 4) {
                val b = bytes[i + 2 + bi].toInt() and 0xFF
                for (bit in 0 until 8) {
                    if ((b and (0x80 shr bit)) != 0) {
                        val num = base + 1 + bi * 8 + bit
                        if (num <= 0xFF) out.add("01%02X".format(num))
                    }
                }
            }
            i += 6
        }
        return out
    }

    /**
     * 解析故障码
     *
     * 兼容三种格式：
     *   ① 标准 ELM327：  43 01 33 02 01 00 00
     *   ② CAN ISO-TP：   [PCI] 43 01 33 02 01 00
     *   ③ ymobd 变体：   可能带计数器前缀
     */
    fun parseDtc(bytes: ByteArray): List<String> {
        val markers = intArrayOf(0x43, 0x47, 0x4A)
        var start = -1
        for (i in bytes.indices) {
            if ((bytes[i].toInt() and 0xFF) in markers) { start = i; break }
        }
        if (start < 0) return emptyList()

        var rest = bytes.copyOfRange(start + 1, bytes.size)

        // ISO-TP PCI：响应码前一个字节，高 4 位 0，低 4 位 = 长度
        if (start >= 1) {
            val pci = bytes[start - 1].toInt() and 0xFF
            val declared = pci and 0x0F
            val actual = bytes.size - start
            if ((pci and 0xF0) == 0x00 && declared in 1..8 && declared <= actual) {
                rest = rest.copyOfRange(0, minOf(rest.size, maxOf(0, declared - 1)))
            }
        }

        // 计数器：剩余长度为奇数且首字节 = 对数
        if (rest.size >= 3 && rest.size % 2 == 1) {
            val cnt = rest[0].toInt() and 0xFF
            if (cnt in 1..20 && rest.size == cnt * 2 + 1) {
                rest = rest.copyOfRange(1, rest.size)
            }
        }

        val out = ArrayList<String>()
        var i = 0
        while (i + 1 < rest.size) {
            val a = rest[i].toInt() and 0xFF
            val b = rest[i + 1].toInt() and 0xFF
            i += 2
            if (a == 0 && b == 0) break
            if (a == 0xFF && b == 0xFF) continue
            if (a == 0xAA && b == 0xAA) continue

            val letter = when ((a and 0xC0) shr 6) {
                0 -> 'P'
                1 -> 'C'
                2 -> 'B'
                else -> 'U'
            }
            val d1 = (a and 0x30) shr 4
            val d2 = a and 0x0F
            out.add("%c%X%X%02X".format(letter, d1, d2, b))
        }
        return out
    }

    /** 字节数组转可读文本 */
    fun debugText(bytes: ByteArray): String =
        bytes.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
}
