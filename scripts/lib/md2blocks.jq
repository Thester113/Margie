# md2blocks.jq — turn simple Markdown (as produced by Margie's planner/QA
# prompts) into an array of Notion block objects. Used with:  jq -Rs -f
#
# Supported per line: # / ## / ### headings, "- [ ]"/"- [x]" to_dos, "- " and
# "* " bullets, "1. " numbered items, "> " quotes, ``` fenced code (language
# kept), "---" divider, blank lines (skipped), everything else = paragraph.
# Text over 1900 chars is split across blocks (Notion caps rich_text at 2000).
def rt($s): [{type: "text", text: {content: $s}}];
def chunks: [scan(".{1,1900}"; "s")] | if length == 0 then [""] else . end;
def para($s): $s | chunks | map({object: "block", type: "paragraph", paragraph: {rich_text: rt(.)}});
def block($type; $s): $s | chunks | map({object: "block", type: $type} + {($type): {rich_text: rt(.)}});

split("\n")
| reduce .[] as $line ({blocks: [], code: null, lang: ""};
    if .code != null then
      if ($line | startswith("```")) then
        .blocks += [{object: "block", type: "code",
                     code: {rich_text: rt(.code | join("\n") | .[0:1900]), language: (if .lang == "" then "plain text" else .lang end)}}]
        | .code = null | .lang = ""
      else .code += [$line] end
    elif ($line | startswith("```")) then
      .code = [] | .lang = ($line | ltrimstr("```") | gsub("\\s"; ""))
    elif ($line | test("^\\s*$")) then .
    elif ($line | startswith("### ")) then .blocks += block("heading_3"; $line[4:])
    elif ($line | startswith("## "))  then .blocks += block("heading_2"; $line[3:])
    elif ($line | startswith("# "))   then .blocks += block("heading_1"; $line[2:])
    elif ($line | test("^- \\[[ xX]\\] ")) then
      .blocks += [{object: "block", type: "to_do",
                   to_do: {rich_text: rt($line | sub("^- \\[[ xX]\\] "; "") | .[0:1900]),
                           checked: ($line | test("^- \\[[xX]\\]"))}}]
    elif ($line | test("^[-*] "))  then .blocks += block("bulleted_list_item"; $line[2:])
    elif ($line | test("^\\d+\\. ")) then .blocks += block("numbered_list_item"; $line | sub("^\\d+\\. "; ""))
    elif ($line | startswith("> "))  then .blocks += block("quote"; $line[2:])
    elif ($line | test("^---+$"))    then .blocks += [{object: "block", type: "divider", divider: {}}]
    else .blocks += para($line) end)
| .blocks
