package com.james.easysave.provenance

/**
 * Pure JVM XML scanner and AST for offset-aware XMP rewriting,
 * precisely matching provenance_dart's xml_scanner.dart behavior.
 */
class XmlAttr(
    val qualifiedName: String,
    val prefix: String?,
    val localName: String,
    val namespaceUri: String?,
    val value: String,
    val nameStart: Int,
    val valueStart: Int,
    val valueStop: Int,
    val quote: Char,
) {
    val isNamespaceDeclaration: Boolean
        get() = qualifiedName == "xmlns" || prefix == "xmlns"
}

class XmlTextNode(
    val start: Int,
    val stop: Int,
    val raw: String,
    val decoded: String,
)

class XmlElementNode(
    val qualifiedName: String,
    val prefix: String?,
    val localName: String,
    val namespaceUri: String?,
    val startTagStart: Int,
    val startTagStop: Int,
    val isSelfClosing: Boolean,
    val attributes: List<XmlAttr>,
) {
    val children = mutableListOf<XmlElementNode>()
    val texts = mutableListOf<XmlTextNode>()
    var parent: XmlElementNode? = null
    var endTagStart: Int? = null
    var endTagStop: Int? = null

    val text: String
        get() = texts.joinToString("") { it.decoded }

    val descendants: Sequence<XmlElementNode>
        get() = sequence {
            for (child in children) {
                yield(child)
                yieldAll(child.descendants)
            }
        }

    fun find(targetNamespaceUri: String?, targetLocalName: String): XmlElementNode? {
        for (node in descendants) {
            if (node.namespaceUri == targetNamespaceUri && node.localName == targetLocalName) {
                return node
            }
        }
        return null
    }

    fun attribute(targetNamespaceUri: String?, targetLocalName: String): XmlAttr? {
        for (attr in attributes) {
            if (attr.namespaceUri == targetNamespaceUri && attr.localName == targetLocalName) {
                return attr
            }
        }
        return null
    }

    val namespaceDeclarations: Map<String, String>
        get() {
            val result = mutableMapOf<String, String>()
            for (attr in attributes) {
                if (!attr.isNamespaceDeclaration) continue
                val p = if (attr.qualifiedName == "xmlns") "" else attr.localName
                result[p] = attr.value
            }
            return result
        }

    fun prefixFor(uri: String): String? {
        var node: XmlElementNode? = this
        while (node != null) {
            for ((p, u) in node.namespaceDeclarations) {
                if (u == uri && p.isNotEmpty()) return p
            }
            node = node.parent
        }
        return null
    }
}

object XmlScanner {
    private fun isSpace(c: Char): Boolean = c == ' ' || c == '\t' || c == '\n' || c == '\r'

    fun decodeEntities(text: String): String {
        if (!text.contains('&')) return text
        val sb = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '&') {
                val semi = text.indexOf(';', i)
                if (semi > i && semi <= i + 10) {
                    val ent = text.substring(i + 1, semi)
                    when {
                        ent == "amp" -> { sb.append('&'); i = semi + 1; continue }
                        ent == "lt" -> { sb.append('<'); i = semi + 1; continue }
                        ent == "gt" -> { sb.append('>'); i = semi + 1; continue }
                        ent == "quot" -> { sb.append('"'); i = semi + 1; continue }
                        ent == "apos" -> { sb.append('\''); i = semi + 1; continue }
                        ent.startsWith("#x") || ent.startsWith("#X") -> {
                            val code = ent.substring(2).toIntOrNull(16)
                            if (code != null) { sb.append(code.toChar()); i = semi + 1; continue }
                        }
                        ent.startsWith("#") -> {
                            val code = ent.substring(1).toIntOrNull()
                            if (code != null) { sb.append(code.toChar()); i = semi + 1; continue }
                        }
                    }
                }
            }
            sb.append(c)
            i++
        }
        return sb.toString()
    }

    fun parseXmlTree(source: String): XmlElementNode {
        var root: XmlElementNode? = null
        val stack = ArrayDeque<XmlElementNode>()
        var pos = 0
        val len = source.length

        // Track namespace scope stack: List of Map<prefix, uri>
        val nsScopeStack = ArrayDeque<Map<String, String>>()
        nsScopeStack.addLast(emptyMap())

        while (pos < len) {
            val nextLt = source.indexOf('<', pos)
            if (nextLt == -1) break

            if (nextLt > pos && stack.isNotEmpty()) {
                val textRaw = source.substring(pos, nextLt)
                stack.last().texts.add(
                    XmlTextNode(
                        start = pos,
                        stop = nextLt,
                        raw = textRaw,
                        decoded = decodeEntities(textRaw),
                    )
                )
            }

            if (source.startsWith("<!--", nextLt)) {
                val endComment = source.indexOf("-->", nextLt + 4)
                pos = if (endComment == -1) len else endComment + 3
                continue
            }
            if (source.startsWith("<?", nextLt)) {
                val endPi = source.indexOf("?>", nextLt + 2)
                pos = if (endPi == -1) len else endPi + 2
                continue
            }
            if (source.startsWith("<![CDATA[", nextLt)) {
                val endCdata = source.indexOf("]]>", nextLt + 9)
                val cdataStop = if (endCdata == -1) len else endCdata + 3
                if (stack.isNotEmpty()) {
                    val raw = source.substring(nextLt, cdataStop)
                    val content = if (endCdata == -1) source.substring(nextLt + 9) else source.substring(nextLt + 9, endCdata)
                    stack.last().texts.add(XmlTextNode(nextLt, cdataStop, raw, content))
                }
                pos = cdataStop
                continue
            }
            if (source.startsWith("<!", nextLt)) {
                val endDoc = source.indexOf('>', nextLt + 2)
                pos = if (endDoc == -1) len else endDoc + 1
                continue
            }

            if (source.startsWith("</", nextLt)) {
                // End element
                val endGt = source.indexOf('>', nextLt + 2)
                if (endGt == -1) break
                if (stack.isNotEmpty()) {
                    val node = stack.removeLast()
                    node.endTagStart = nextLt
                    node.endTagStop = endGt + 1
                    if (nsScopeStack.size > 1) {
                        nsScopeStack.removeLast()
                    }
                }
                pos = endGt + 1
                continue
            }

            // Start element
            // Find end of start tag (handle quotes inside attributes)
            var tagClose = -1
            var inQuote: Char? = null
            for (idx in (nextLt + 1) until len) {
                val ch = source[idx]
                if (inQuote != null) {
                    if (ch == inQuote) inQuote = null
                } else {
                    if (ch == '"' || ch == '\'') inQuote = ch
                    else if (ch == '>') { tagClose = idx; break }
                }
            }
            if (tagClose == -1) break

            val isSelfClosing = source[tagClose - 1] == '/'
            val startTagStart = nextLt
            val startTagStop = tagClose + 1

            // Parse element name
            var nameEnd = nextLt + 1
            while (nameEnd < tagClose && !isSpace(source[nameEnd]) && source[nameEnd] != '/' && source[nameEnd] != '>') {
                nameEnd++
            }
            val qualifiedName = source.substring(nextLt + 1, nameEnd)
            val prefix = if (qualifiedName.contains(':')) qualifiedName.substringBefore(':') else null
            val localName = if (qualifiedName.contains(':')) qualifiedName.substringAfter(':') else qualifiedName

            // Parse raw attributes
            val rawAttrs = parseRawAttributes(source, nameEnd, if (isSelfClosing) tagClose - 1 else tagClose)

            // Resolve namespaces for this element
            val currentNsMap = HashMap(nsScopeStack.last())
            for (ra in rawAttrs) {
                if (ra.qName == "xmlns") {
                    currentNsMap[""] = ra.value
                } else if (ra.qName.startsWith("xmlns:")) {
                    currentNsMap[ra.qName.substring(6)] = ra.value
                }
            }
            nsScopeStack.addLast(currentNsMap)

            val elemNsUri = currentNsMap[prefix ?: ""]

            val resolvedAttrs = rawAttrs.map { ra ->
                val aPrefix = if (ra.qName.contains(':')) ra.qName.substringBefore(':') else null
                val aLocal = if (ra.qName.contains(':')) ra.qName.substringAfter(':') else ra.qName
                val aNs = if (ra.qName == "xmlns" || aPrefix == "xmlns") {
                    "http://www.w3.org/2000/xmlns/"
                } else if (aPrefix != null) {
                    currentNsMap[aPrefix]
                } else null

                XmlAttr(
                    qualifiedName = ra.qName,
                    prefix = aPrefix,
                    localName = aLocal,
                    namespaceUri = aNs,
                    value = ra.value,
                    nameStart = ra.nameStart,
                    valueStart = ra.valueStart,
                    valueStop = ra.valueStop,
                    quote = ra.quote,
                )
            }

            val node = XmlElementNode(
                qualifiedName = qualifiedName,
                prefix = prefix,
                localName = localName,
                namespaceUri = elemNsUri,
                startTagStart = startTagStart,
                startTagStop = startTagStop,
                isSelfClosing = isSelfClosing,
                attributes = resolvedAttrs,
            )

            if (stack.isEmpty()) {
                if (root == null) root = node
            } else {
                node.parent = stack.last()
                stack.last().children.add(node)
            }

            if (!isSelfClosing) {
                stack.addLast(node)
            } else {
                nsScopeStack.removeLast()
            }

            pos = startTagStop
        }

        return root ?: throw IllegalArgumentException("XML document has no root element")
    }

    private class RawAttr(
        val qName: String,
        val value: String,
        val nameStart: Int,
        val valueStart: Int,
        val valueStop: Int,
        val quote: Char,
    )

    private fun parseRawAttributes(source: String, start: Int, stop: Int): List<RawAttr> {
        val result = mutableListOf<RawAttr>()
        var pos = start

        while (pos < stop) {
            while (pos < stop && isSpace(source[pos])) pos++
            if (pos >= stop) break

            val nameStart = pos
            while (pos < stop && !isSpace(source[pos]) && source[pos] != '=') pos++
            val qName = source.substring(nameStart, pos)

            while (pos < stop && isSpace(source[pos])) pos++
            if (pos < stop && source[pos] == '=') pos++
            while (pos < stop && isSpace(source[pos])) pos++

            var quote = '"'
            if (pos < stop && (source[pos] == '"' || source[pos] == '\'')) {
                quote = source[pos]
                pos++
            }
            val valueStart = pos
            while (pos < stop && source[pos] != quote) pos++
            val valueStop = pos
            if (pos < stop && source[pos] == quote) pos++

            val rawVal = source.substring(valueStart, valueStop)
            result.add(
                RawAttr(
                    qName = qName,
                    value = decodeEntities(rawVal),
                    nameStart = nameStart,
                    valueStart = valueStart,
                    valueStop = valueStop,
                    quote = quote,
                )
            )
        }
        return result
    }
}

