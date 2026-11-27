package com.james.easysave.provenance

/**
 * XmpPackage for editing in place or creating new XMP XML packages,
 * replicating package:provenance_dart/src/xmp_package.dart.
 */
class XmpPackage private constructor(private var _text: String) {

    companion object {
        const val PROV_NS_URI = "https://joopererer.github.io/provenance-spec/ns/"
        const val DC_NS_URI = "http://purl.org/dc/elements/1.1/"
        const val XMP_NS_URI = "http://ns.adobe.com/xap/1.0/"
        const val PHOTOSHOP_NS_URI = "http://ns.adobe.com/photoshop/1.0/"
        const val IPTC_EXT_NS_URI = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        const val RDF_NS_URI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        const val XML_NS_URI = "http://www.w3.org/XML/1998/namespace"
        const val ADOBE_META_NS_URI = "adobe:ns:meta/"

        private const val SKELETON =
            "<?xpacket begin=\"\uFEFF\" " +
            "id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" +
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n" +
            " <rdf:RDF xmlns:rdf=\"$RDF_NS_URI\">\n" +
            "  <rdf:Description rdf:about=\"\"" +
            " xmlns:prov=\"$PROV_NS_URI\"" +
            " xmlns:dc=\"$DC_NS_URI\"" +
            " xmlns:xmp=\"$XMP_NS_URI\"" +
            " xmlns:photoshop=\"$PHOTOSHOP_NS_URI\"/>\n" +
            " </rdf:RDF>\n" +
            "</x:xmpmeta>\n" +
            "<?xpacket end=\"w\"?>"

        fun empty(): XmpPackage = XmpPackage(SKELETON)

        fun parse(text: String): XmpPackage = XmpPackage(text)

        fun escapeAttributeValue(value: String, quote: Char): String {
            val sb = StringBuilder()
            for (ch in value) {
                when (ch) {
                    '&' -> sb.append("&amp;")
                    '<' -> sb.append("&lt;")
                    '"' -> sb.append(if (quote == '"') "&quot;" else "\"")
                    '\'' -> sb.append(if (quote == '\'') "&apos;" else "'")
                    '\n' -> sb.append("&#10;")
                    '\r' -> sb.append("&#13;")
                    '\t' -> sb.append("&#9;")
                    else -> sb.append(ch)
                }
            }
            return sb.toString()
        }

        fun escapeText(value: String): String {
            val sb = StringBuilder()
            for (ch in value) {
                when (ch) {
                    '&' -> sb.append("&amp;")
                    '<' -> sb.append("&lt;")
                    '>' -> sb.append("&gt;")
                    '\r' -> sb.append("&#13;")
                    else -> sb.append(ch)
                }
            }
            return sb.toString()
        }
    }

    private var _root: XmlElementNode = XmlScanner.parseXmlTree(_text)

    val text: String
        get() = _text

    val descriptions: List<XmlElementNode>
        get() = _root.descendants.filter { it.namespaceUri == RDF_NS_URI && it.localName == "Description" }.toList()

    fun hasField(field: XmpFieldSpec): Boolean {
        return _findAttribute(field) != null || _findElement(field) != null
    }

    fun setField(field: XmpFieldSpec, value: Any?) {
        if (value == null) return
        if (value is List<*> && value.isEmpty()) {
            removeField(field)
            return
        }
        val textVal = scalarText(value) ?: return

        val attribute = _findAttribute(field)
        if (attribute != null) {
            if (field.kind == XmpValueKind.SCALAR) {
                _apply(attribute.valueStart, attribute.valueStop, escapeAttributeValue(textVal, attribute.quote))
            } else {
                _apply(attribute.nameStart, attribute.valueStop + 1, "")
                _insertField(field, value, textVal)
            }
            return
        }

        val element = _findElement(field)
        if (element != null) {
            _updateElement(element, field, value, textVal)
            return
        }

        _insertField(field, value, textVal)
    }

    fun setQualifiedField(qualifiedName: String, value: String) {
        val attribute = descriptions.firstOrNull()?.attributes?.firstOrNull { it.qualifiedName == qualifiedName }
        if (attribute != null) {
            _apply(attribute.valueStart, attribute.valueStop, escapeAttributeValue(value, attribute.quote))
            return
        }
        val description = _ensureDescription()
        _insertAttribute(description, " $qualifiedName=\"${escapeAttributeValue(value, '"')}\"")
    }

    fun removeField(field: XmpFieldSpec) {
        val attribute = _findAttribute(field)
        if (attribute != null) {
            var start = attribute.nameStart
            while (start > 0 && XmlScanner.decodeEntities(_text.substring(start - 1, start)).first().isWhitespace()) {
                start--
            }
            _apply(start, attribute.valueStop + 1, "")
            return
        }
        val element = _findElement(field)
        if (element != null) {
            val stop = element.endTagStop ?: element.startTagStop
            _apply(element.startTagStart, stop, "")
        }
    }

    private fun _updateElement(element: XmlElementNode, field: XmpFieldSpec, value: Any, textVal: String) {
        if (field.kind == XmpValueKind.SCALAR) {
            _replaceContent(element, escapeText(textVal))
            return
        }
        if (field.kind == XmpValueKind.ALT_TEXT) {
            val alt = element.find(RDF_NS_URI, "Alt")
            if (alt == null) {
                _replaceContent(element, _containerInner(element, field, value))
                return
            }
            val items = alt.children.filter { it.namespaceUri == RDF_NS_URI && it.localName == "li" }
            if (items.isEmpty()) {
                _insertContent(alt, itemMarkup(element, textVal, language = "x-default"))
                return
            }
            val target = items.firstOrNull { it.attribute(XML_NS_URI, "lang")?.value == "x-default" } ?: items.first()
            _replaceContent(target, escapeText(textVal))
            return
        }

        val containerName = if (field.kind == XmpValueKind.SEQUENCE) "Seq" else "Bag"
        val container = element.find(RDF_NS_URI, containerName)
        if (container == null) {
            _replaceContent(element, _containerInner(element, field, value))
            return
        }
        val itemsList = if (value is List<*>) value else listOf(value)
        val itemsMarkup = itemsList.joinToString("") { itemMarkup(element, scalarText(it) ?: "") }
        _replaceContent(container, itemsMarkup)
    }

    private fun _insertField(field: XmpFieldSpec, value: Any, textVal: String) {
        val description = _ensureDescription()
        val prefix = _ensurePrefix(description, field)
        val target = _ensureDescription()

        if (field.kind == XmpValueKind.SCALAR) {
            _insertAttribute(target, " $prefix:${field.localName}=\"${escapeAttributeValue(textVal, '"')}\"")
        } else {
            val rdfPrefix = target.prefixFor(RDF_NS_URI) ?: "rdf"
            _insertContent(
                target,
                "<$prefix:${field.localName}>${_containerInner(target, field, value, rdfPrefix = rdfPrefix)}</$prefix:${field.localName}>"
            )
        }
    }

    private fun _ensurePrefix(description: XmlElementNode, field: XmpFieldSpec): String {
        val existing = description.prefixFor(field.namespaceUri)
        if (existing != null) return existing
        val prefix = field.preferredPrefix
        _insertAttribute(description, " xmlns:$prefix=\"${escapeAttributeValue(field.namespaceUri, '"')}\"")
        return prefix
    }

    private fun _ensureDescription(): XmlElementNode {
        val existing = descriptions
        if (existing.isNotEmpty()) return existing.first()
        val rdf = _root.find(RDF_NS_URI, "RDF") ?: throw IllegalStateException("XMP package has no rdf:RDF element")
        val rdfPrefix = rdf.prefixFor(RDF_NS_URI) ?: rdf.prefix ?: "rdf"
        _insertContent(rdf, "<$rdfPrefix:Description $rdfPrefix:about=\"\"/>")
        return descriptions.first()
    }

    private fun _containerInner(context: XmlElementNode, field: XmpFieldSpec, value: Any, rdfPrefix: String? = null): String {
        val prefix = rdfPrefix ?: context.prefixFor(RDF_NS_URI) ?: "rdf"
        if (field.kind == XmpValueKind.ALT_TEXT) {
            val t = scalarText(value) ?: ""
            return "<$prefix:Alt><$prefix:li xml:lang=\"x-default\">${escapeText(t)}</$prefix:li></$prefix:Alt>"
        }
        val container = if (field.kind == XmpValueKind.SEQUENCE) "Seq" else "Bag"
        val itemsList = if (value is List<*>) value else listOf(value)
        val itemsMarkup = itemsList.joinToString("") {
            "<$prefix:li>${escapeText(scalarText(it) ?: "")}</$prefix:li>"
        }
        return "<$prefix:$container>$itemsMarkup</$prefix:$container>"
    }

    private fun itemMarkup(context: XmlElementNode, textVal: String, language: String? = null): String {
        val prefix = context.prefixFor(RDF_NS_URI) ?: "rdf"
        val langAttr = if (language != null) " xml:lang=\"$language\"" else ""
        return "<$prefix:li$langAttr>${escapeText(textVal)}</$prefix:li>"
    }

    private fun _insertAttribute(node: XmlElementNode, markup: String) {
        val at = if (node.isSelfClosing) node.startTagStop - 2 else node.startTagStop - 1
        _apply(at, at, markup)
    }

    private fun _insertContent(node: XmlElementNode, markup: String) {
        if (node.isSelfClosing) {
            _apply(node.startTagStop - 2, node.startTagStop, ">$markup</${node.qualifiedName}>")
        } else {
            val endTag = node.endTagStart!!
            _apply(endTag, endTag, markup)
        }
    }

    private fun _replaceContent(node: XmlElementNode, markup: String) {
        if (node.isSelfClosing) {
            _apply(node.startTagStop - 2, node.startTagStop, ">$markup</${node.qualifiedName}>")
        } else {
            _apply(node.startTagStop, node.endTagStart!!, markup)
        }
    }

    private fun _apply(start: Int, stop: Int, replacement: String) {
        _text = _text.substring(0, start) + replacement + _text.substring(stop)
        _root = XmlScanner.parseXmlTree(_text)
    }

    fun getField(field: XmpFieldSpec): String? {
        val attr = _findAttribute(field)
        if (attr != null) return attr.value
        val elem = _findElement(field)
        if (elem != null) return elem.text
        return null
    }

    fun getField(namespaceUri: String, localName: String): String? {
        for (desc in descriptions) {
            val attr = desc.attribute(namespaceUri, localName)
            if (attr != null) return attr.value
            val elem = desc.find(namespaceUri, localName)
            if (elem != null) return elem.text
        }
        return null
    }

    private fun _findAttribute(field: XmpFieldSpec): XmlAttr? {
        for (desc in descriptions) {
            val attr = desc.attribute(field.namespaceUri, field.localName)
            if (attr != null) return attr
        }
        return null
    }

    private fun _findElement(field: XmpFieldSpec): XmlElementNode? {
        for (desc in descriptions) {
            val elem = desc.find(field.namespaceUri, field.localName)
            if (elem != null) return elem
        }
        return null
    }

    private fun scalarText(value: Any?): String? {
        if (value == null) return null
        if (value is List<*>) return if (value.isEmpty()) null else value.first()?.toString()
        return value.toString()
    }
}

enum class XmpValueKind { SCALAR, ALT_TEXT, SEQUENCE, BAG }
enum class XmpFieldClass { CAPTURE, USER, SYSTEM }

class XmpFieldSpec(
    val namespaceUri: String,
    val localName: String,
    val kind: XmpValueKind,
    val fieldClass: XmpFieldClass,
) {
    val preferredPrefix: String
        get() = when (namespaceUri) {
            XmpPackage.PROV_NS_URI -> "prov"
            XmpPackage.DC_NS_URI -> "dc"
            XmpPackage.XMP_NS_URI -> "xmp"
            XmpPackage.PHOTOSHOP_NS_URI -> "photoshop"
            XmpPackage.IPTC_EXT_NS_URI -> "Iptc4xmpExt"
            else -> "ns"
        }

    val qualifiedName: String
        get() = "$preferredPrefix:$localName"
}

object XmpFields {
    val SCHEMA = XmpFieldSpec(XmpPackage.PROV_NS_URI, "schema", XmpValueKind.SCALAR, XmpFieldClass.SYSTEM)
    val ASSET_ID = XmpFieldSpec(XmpPackage.PROV_NS_URI, "assetId", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val CAPTURED_AT = XmpFieldSpec(XmpPackage.PROV_NS_URI, "capturedAt", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val CAPTURED_BY = XmpFieldSpec(XmpPackage.PROV_NS_URI, "capturedBy", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val METADATA_DATE = XmpFieldSpec(XmpPackage.XMP_NS_URI, "MetadataDate", XmpValueKind.SCALAR, XmpFieldClass.SYSTEM)
    val SOURCE_URL = XmpFieldSpec(XmpPackage.PROV_NS_URI, "sourceUrl", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val PLATFORM = XmpFieldSpec(XmpPackage.PROV_NS_URI, "platform", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val SOURCE_ID = XmpFieldSpec(XmpPackage.PROV_NS_URI, "sourceId", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val ITEM_INDEX = XmpFieldSpec(XmpPackage.PROV_NS_URI, "itemIndex", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val ITEM_COUNT = XmpFieldSpec(XmpPackage.PROV_NS_URI, "itemCount", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val AUTHOR_ID = XmpFieldSpec(XmpPackage.PROV_NS_URI, "authorId", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val PUBLISHED_AT = XmpFieldSpec(XmpPackage.PROV_NS_URI, "publishedAt", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val PAIR_ID = XmpFieldSpec(XmpPackage.PROV_NS_URI, "pairId", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val TITLE = XmpFieldSpec(XmpPackage.DC_NS_URI, "title", XmpValueKind.ALT_TEXT, XmpFieldClass.USER)
    val CREATOR = XmpFieldSpec(XmpPackage.DC_NS_URI, "creator", XmpValueKind.SEQUENCE, XmpFieldClass.USER)
    val DESCRIPTION = XmpFieldSpec(XmpPackage.DC_NS_URI, "description", XmpValueKind.ALT_TEXT, XmpFieldClass.USER)
    val SUBJECT = XmpFieldSpec(XmpPackage.DC_NS_URI, "subject", XmpValueKind.BAG, XmpFieldClass.USER)
    val RATING = XmpFieldSpec(XmpPackage.XMP_NS_URI, "Rating", XmpValueKind.SCALAR, XmpFieldClass.USER)
    val CREDIT = XmpFieldSpec(XmpPackage.PHOTOSHOP_NS_URI, "Credit", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val AI_LABEL = XmpFieldSpec(XmpPackage.PROV_NS_URI, "aiLabel", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val AI_LABEL_SOURCE = XmpFieldSpec(XmpPackage.PROV_NS_URI, "aiLabelSource", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val DIGITAL_SOURCE_TYPE = XmpFieldSpec(XmpPackage.IPTC_EXT_NS_URI, "DigitalSourceType", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
    val DC_SOURCE = XmpFieldSpec(XmpPackage.DC_NS_URI, "source", XmpValueKind.SCALAR, XmpFieldClass.CAPTURE)
}

object XmpCore {
    fun buildXmpXml(record: ProvenanceRecord): String {
        val pkg = XmpPackage.empty()
        writeRecordIntoPackage(pkg, record)
        return pkg.text
    }

    fun updateXmpXml(xml: String, record: ProvenanceRecord): String {
        return try {
            val pkg = XmpPackage.parse(xml)
            writeRecordIntoPackage(pkg, record)
            pkg.text
        } catch (_: Exception) {
            buildXmpXml(record)
        }
    }

    fun writeRecordIntoPackage(pkg: XmpPackage, record: ProvenanceRecord) {
        val fieldMap = LinkedHashMap<XmpFieldSpec, Any?>()
        fieldMap[XmpFields.SCHEMA] = record.schema
        fieldMap[XmpFields.ASSET_ID] = record.assetId
        fieldMap[XmpFields.CAPTURED_AT] = ProvenanceRecord.normalizeDate(record.capturedAt)
        fieldMap[XmpFields.CAPTURED_BY] = record.capturedBy
        fieldMap[XmpFields.METADATA_DATE] = ProvenanceRecord.normalizeDate(record.metadataDate)
        fieldMap[XmpFields.SOURCE_URL] = record.sourceUrl
        fieldMap[XmpFields.PLATFORM] = record.platform
        fieldMap[XmpFields.SOURCE_ID] = record.sourceId
        fieldMap[XmpFields.ITEM_INDEX] = record.itemIndex
        fieldMap[XmpFields.ITEM_COUNT] = record.itemCount
        fieldMap[XmpFields.AUTHOR_ID] = record.authorId
        fieldMap[XmpFields.PUBLISHED_AT] = ProvenanceRecord.normalizeDate(record.publishedAt)
        fieldMap[XmpFields.PAIR_ID] = record.pairId
        fieldMap[XmpFields.TITLE] = record.title
        fieldMap[XmpFields.CREATOR] = record.creator
        fieldMap[XmpFields.DESCRIPTION] = record.description
        fieldMap[XmpFields.SUBJECT] = record.subject
        fieldMap[XmpFields.RATING] = record.rating
        fieldMap[XmpFields.CREDIT] = record.credit
        fieldMap[XmpFields.AI_LABEL] = record.aiLabel
        fieldMap[XmpFields.AI_LABEL_SOURCE] = record.aiLabelSource
        fieldMap[XmpFields.DIGITAL_SOURCE_TYPE] = record.digitalSourceType
        fieldMap[XmpFields.DC_SOURCE] = record.sourceUrl

        for ((field, value) in fieldMap) {
            if (value == null) continue
            if (field.fieldClass == XmpFieldClass.CAPTURE && pkg.hasField(field)) {
                continue
            }
            pkg.setField(field, value)
        }
        for ((k, v) in record.otherFields) {
            pkg.setQualifiedField(k, v)
        }
    }
}

