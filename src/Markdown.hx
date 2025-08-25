import markdown.AST;
import markdown.BlockParser;
import markdown.HtmlRenderer;
import markdown.InlineParser;

using StringTools;
using Lambda;

class Markdown {
	#if sys
	public static function main() {
		var args = Sys.args();

		var last:String = (new haxe.io.Path(args[args.length - 1])).toString();
		var slash = last.substr(-1);
		if (slash == "/" || slash == "\\")
			last = last.substr(0, last.length - 1);
		if (sys.FileSystem.exists(last) && sys.FileSystem.isDirectory(last)) {
			Sys.setCwd(last);
		}

		var source = args[0];
		if (source == "-f")
			source = sys.io.File.getContent(args[1]);

		try {
			var output = markdownToHtml(source);
			Sys.print(output);
			Sys.exit(0);
		} catch (e:Dynamic) {
			Sys.print("Error: " + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			Sys.exit(1);
		}
	}
	#end

	public static function markdownToHtml(markdown:String):String {
		// create document
		var document = new Document();

		try {
			// replace windows line endings with unix, and split
			var lines = ~/(\r\n|\r)/g.replace(markdown, '\n').split("\n");

			// parse ref links
			document.parseFootnotes(lines);
			document.parseRefLinks(lines);

			// parse ast
			var parsedInline = document.parseLines(lines);
			var blocks = document.filterFootnotes(parsedInline);
			return renderHtml(blocks);
		} catch (e:Dynamic) {
			return '<pre>$e</pre>';
		}
	}

	public static function renderHtml(blocks:Array<Node>):String {
		return new HtmlRenderer().render(blocks);
	}
}

/**
	Maintains the context needed to parse a markdown document.
**/
class Document {
	public var refLinks:Map<String, Link>;
	public var refFootnotes:Map<String, Footnote>;
	public var inlineSyntaxes:Array<InlineSyntax>;
	public var linkResolver:Resolver;
	public var codeBlockSyntaxes:Map<String, String->String>;

	public function new() {
		refLinks = new Map();
		refFootnotes = new Map();
		codeBlockSyntaxes = new Map();
		inlineSyntaxes = [];
	}

	public function parseFootnotes(lines:Array<String>) {
		var indent = '^[ ]{0,3}';
		var id = '\\[\\^([^\\]\\s]+)\\]';
		var footnote = new EReg('$indent$id:\\s+(.+)$', '');

		for (i in 0...lines.length) {
			if (!footnote.match(lines[i]))
				continue;

			var id = footnote.matched(1).toLowerCase();
			var content = footnote.matched(2);
			var footnoteNumber = refFootnotes.count() + 1;
			var count = 0;

			refFootnotes.set(id, new Footnote(id, content, footnoteNumber, count));
		}
	}

	public function parseRefLinks(lines:Array<String>) {
		// This is a hideous regex. It matches:
		// [id]: http:foo.com "some title"
		// Where there may whitespace in there, and where the title may be in
		// single quotes, double quotes, or parentheses.
		var indent = '^[ ]{0,3}'; // Leading indentation.
		// var id = '\\[([^\\]]+)\\]'; // Reference id in [brackets].
		var id = '\\[(?!\\^)([^\\]]+)\\]'; // Reference id in [brackets].
		var quote = '"[^"]+"'; // Title in "double quotes".
		var apos = "'[^']+'"; // Title in 'single quotes'.
		var paren = "\\([^)]+\\)"; // Title in (parentheses).
		var titles = new EReg('($quote|$apos|$paren)', '');
		var link = new EReg('$indent$id:\\s+(\\S+)\\s*($quote|$apos|$paren|)\\s*$', '');

		for (i in 0...lines.length) {
			if (!link.match(lines[i]))
				continue;

			// Parse the link.
			var id = link.matched(1);
			var url = link.matched(2);
			var title = link.matched(3);

			if (url.startsWith('<') && url.endsWith('>'))
				url = url.substr(1, url.length - 2);

			// next line could be a title, apparently
			if (title == '' && lines[i + 1] != null && titles.match(lines[i + 1])) {
				title = titles.matched(1);
				lines[i + 1] = '';
			}

			if (title == '') {
				// No title.
				title = null;
			} else {
				// Remove "", '', or ().
				title = title.substring(1, title.length - 1);
			}

			// References are case-insensitive.
			id = id.toLowerCase();
			refLinks.set(id, new Link(id, url, title));

			// Remove it from the output. We replace it with a blank line which
			// will get consumed by later processing.
			lines[i] = '';
		}
	}

	/**
		Parse the given [lines] of markdown to a series of AST nodes.
	**/
	public function parseLines(lines:Array<String>):Array<Node> {
		var parser = new BlockParser(lines, this);
		var blocks = [];

		while (!parser.isDone) {
			for (syntax in BlockSyntax.syntaxes) {
				if (syntax.canParse(parser)) {
					var block = syntax.parse(parser);
					if (block != null)
						blocks.push(block);
					break;
				}
			}
		}

		return blocks;
	}

	public function filterFootnotes(nodes:Array<Node>):Array<Node> {
		var footnotes:Array<Node> = [];
		var blocks:Array<Node> = [];

		// This system is fucking ass! maybe there is a better way to do this...
		for (node in nodes) {
			if (Std.isOfType(node, ElementNode)) {
				var el:ElementNode = cast node;
				// Finds an item list
				if (el.tag == "li" && el.attributes.get('id') != null) {
					var id = el.attributes.get('id');
					// Makes sure this node is a footnote by comparing whether or not the id of it is in footnotes
					if (id != null && refFootnotes.exists(id.substring(3))) {
						footnotes.push(el);

						var footnote = refFootnotes.get(id.substring(3));
						var children = el.children;

						if (!children.empty()) {
							var backRef = new ElementNode('a', [new TextNode(' ↩')]);
							backRef.attributes.set('href', '#fnref-' + footnote.id + '-' + footnote.count);

							var lastItem:ElementNode = cast children[children.length - 1];
							lastItem.children.push(backRef);
						}
					}
					continue;
				}
			}
			blocks.push(node);
		}

		if (footnotes.length > 0) {
			var list = new ElementNode('ol', footnotes);
			var section = new ElementNode('section', [list]);
			section.attributes.set('class', 'footnotes');
			blocks.push(ElementNode.empty('hr'));
			blocks.push(section);
		}

		return blocks;
	}

	/**
		Takes a string of raw text and processes all inline markdown tags,
		returning a list of AST nodes. For example, given ``"*this **is** a*
		`markdown`"``, returns:
		`<em>this <strong>is</strong> a</em> <code>markdown</code>`.
	**/
	public function parseInline(text:String):Array<Node> {
		return new InlineParser(text, this).parse();
	}
}

class Link {
	public var id(default, null):String;
	public var url(default, null):String;
	public var title(default, null):String;

	public function new(id:String, url:String, title:String) {
		this.id = id;
		this.url = url;
		this.title = title;
	}
}

class Footnote {
	public var id(default, null):String;
	public var content(default, null):String;
	public var number(default, null):Int;
	public var count:Int;

	public function new(id:String, content:String, number:Int, count:Int) {
		this.id = id;
		this.content = content;
		this.number = number;
		this.count = count;
	}
}

typedef Resolver = String->Node;
