#!/usr/bin/env ksh
# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
# Pure ksh93 (93u+m): no external commands. mkdir, ln, chmod and rm are ksh93's own libcmd
# built-ins; everything else (read, print, printf, [[ ]]) is built into the shell.

PATH=            # no external programs, ever
LC_ALL=C         # byte-level strings: ${#s} and ${s:i:1} count bytes
set -C           # noclobber: '>' never writes through an existing file

function die {
	print -ru2 -- "json2dir: $1"
	exit 1
}

builtin mkdir ln chmod rm 2>/dev/null ||
	builtin -f libcmd.so.2 mkdir ln chmod rm 2>/dev/null ||
	builtin -f libcmd.so mkdir ln chmod rm ||
	die "cannot load the mkdir, ln, chmod and rm built-ins"

# ORD[byte] = byte value, CHR[value] = byte (1..255)
typeset -A ORD
typeset -a CHR
typeset hexd=0123456789abcdef c
integer i
for (( i = 1; i < 256; i++ )); do
	eval "c=\$'\\x${hexd:i/16:1}${hexd:i%16:1}'"
	CHR[i]=$c
	ORD["$c"]=$i
done

# ---------------------------------------------------------------- parser
# The document is flattened into parallel arrays, in document (pre-)order:
#   KIND[k]  d (directory) | f (file) | x (script) | l (link)
#   PATHS[k] path relative to the target directory, names joined with "/"
#   NP[k]    number of NUL-separated parts of the content / link target
#   PART["k,j"] part j (ksh strings cannot hold NUL; parts are joined with NUL bytes on write)
typeset -a KIND PATHS NP SP
typeset -A PART
typeset raw
integer p n NSP

function skip_ws {
	while (( p < n )); do
		case ${raw:p:1} in
		' '|$'\t'|$'\n'|$'\r') (( p++ )) ;;
		*) return ;;
		esac
	done
}

function hex4 {   # 4 hex digits at p -> REPLY (number)
	typeset h=${raw:p:4}
	[[ $h == [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F] ]] || die "invalid JSON at byte $p: bad \\u escape"
	(( p += 4 ))
	REPLY=$(( 16#$h ))
}

function utf8 {   # code point $1 (> 0) -> REPLY as UTF-8 bytes
	integer cp=$1
	if (( cp < 0x80 )); then
		REPLY=${CHR[cp]}
	elif (( cp < 0x800 )); then
		REPLY=${CHR[0xC0 | cp >> 6]}${CHR[0x80 | cp & 0x3F]}
	elif (( cp < 0x10000 )); then
		REPLY=${CHR[0xE0 | cp >> 12]}${CHR[0x80 | (cp >> 6) & 0x3F]}${CHR[0x80 | cp & 0x3F]}
	else
		REPLY=${CHR[0xF0 | cp >> 18]}${CHR[0x80 | (cp >> 12) & 0x3F]}${CHR[0x80 | (cp >> 6) & 0x3F]}${CHR[0x80 | cp & 0x3F]}
	fi
}

# Parses the JSON string at p (at the opening quote) into SP[0..NSP-1]: its UTF-8 bytes,
# split at NUL characters. Validates UTF-8 strictly and rejects unpaired surrogates.
function parse_string {
	typeset c d out=
	integer start b need lo hi j cp cp2
	unset SP
	NSP=0
	(( p++ ))
	start=p
	while :; do
		(( p >= n )) && die "invalid JSON: unterminated string"
		c=${raw:p:1}
		case $c in
		'"')
			out+=${raw:start:p-start}
			(( p++ ))
			break
			;;
		'\')
			out+=${raw:start:p-start}
			d=${raw:p+1:1}
			(( p += 2 ))
			case $d in
			'"') out+='"' ;;
			'\') out+='\' ;;
			'/') out+='/' ;;
			b) out+=$'\b' ;;
			f) out+=$'\f' ;;
			n) out+=$'\n' ;;
			r) out+=$'\r' ;;
			t) out+=$'\t' ;;
			u)
				hex4; cp=$REPLY
				if (( cp >= 0xD800 && cp <= 0xDBFF )); then
					[[ ${raw:p:2} == '\u' ]] || die "string contains an unpaired surrogate"
					(( p += 2 ))
					hex4; cp2=$REPLY
					(( cp2 >= 0xDC00 && cp2 <= 0xDFFF )) || die "string contains an unpaired surrogate"
					cp=$(( 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00) ))
				elif (( cp >= 0xDC00 && cp <= 0xDFFF )); then
					die "string contains an unpaired surrogate"
				fi
				if (( cp == 0 )); then   # NUL: start a new part
					SP[NSP++]=$out
					out=
				else
					utf8 $cp
					out+=$REPLY
				fi
				;;
			*) die "invalid JSON at byte $(( p - 1 )): bad escape" ;;
			esac
			start=p
			;;
		[' '-'~'])
			(( p++ ))
			;;
		*)
			b=${ORD["$c"]}
			(( b < 0x20 )) && die "invalid JSON at byte $p: control character in string"
			if (( b < 0x80 )); then   # DEL
				(( p++ ))
				continue
			fi
			# strict UTF-8: lead byte, then continuation bytes, the first one range-limited
			lo=0x80 hi=0xBF
			if (( b >= 0xC2 && b <= 0xDF )); then need=1
			elif (( b == 0xE0 )); then need=2 lo=0xA0
			elif (( b == 0xED )); then need=2 hi=0x9F
			elif (( b >= 0xE1 && b <= 0xEF )); then need=2
			elif (( b == 0xF0 )); then need=3 lo=0x90
			elif (( b == 0xF4 )); then need=3 hi=0x8F
			elif (( b >= 0xF1 && b <= 0xF3 )); then need=3
			else die "input is not valid UTF-8 (byte $p)"
			fi
			for (( j = 1; j <= need; j++ )); do
				(( p + j < n )) || die "input is not valid UTF-8 (byte $p)"
				d=${raw:p+j:1}
				b=${ORD["$d"]}
				(( b >= lo && b <= hi )) || die "input is not valid UTF-8 (byte $(( p + j )))"
				lo=0x80 hi=0xBF
			done
			(( p += need + 1 ))
			;;
		esac
	done
	SP[NSP++]=$out
}

function add_entry {   # add_entry <kind> <path>  (content from SP)
	integer k=${#KIND[@]} j
	KIND[k]=$1
	PATHS[k]=$2
	NP[k]=$NSP
	for (( j = 0; j < NSP; j++ )); do
		PART["$k,$j"]=${SP[j]}
	done
}

function bad_array {
	die "$1: an array must be [\"link\", target] or [\"script\", content]"
}

function parse_value {   # parse_value <path>
	typeset where=$1 kind
	skip_ws
	case ${raw:p:1} in
	'{') parse_object "$where" ;;
	'"')
		parse_string
		add_entry f "$where"
		;;
	'[')
		(( p++ )); skip_ws
		[[ ${raw:p:1} == '"' ]] || bad_array "$where"
		parse_string
		(( NSP == 1 )) && kind=${SP[0]} || kind=bad
		skip_ws
		[[ ${raw:p:1} == ',' ]] || bad_array "$where"
		(( p++ )); skip_ws
		[[ ${raw:p:1} == '"' ]] || bad_array "$where"
		parse_string
		skip_ws
		[[ ${raw:p:1} == ']' ]] || bad_array "$where"
		(( p++ ))
		case $kind in
		link)
			(( NSP == 1 )) || die "$where: a link target cannot contain NUL"
			add_entry l "$where"
			;;
		script) add_entry x "$where" ;;
		*) die "$where: unknown array kind" ;;
		esac
		;;
	'') die "invalid JSON: unexpected end of input" ;;
	*) die "$where: only objects, strings and arrays are allowed (byte $p)" ;;
	esac
}

function parse_object {   # parse_object <path>; the root is "."
	typeset where=$1 name child
	typeset -A seen
	skip_ws
	[[ ${raw:p:1} == '{' ]] || die "invalid JSON at byte $p: expected '{'"
	(( p++ ))
	if [[ $where != . ]]; then
		NSP=1; SP[0]=
		add_entry d "$where"
	fi
	skip_ws
	if [[ ${raw:p:1} == '}' ]]; then
		(( p++ ))
		return
	fi
	while :; do
		skip_ws
		[[ ${raw:p:1} == '"' ]] || die "invalid JSON at byte $p: expected a member name"
		parse_string
		name=${SP[0]}
		if [[ $where == . ]]; then child=$name; else child=$where/$name; fi
		if (( NSP != 1 )) || [[ -z $name || $name == . || $name == .. || $name == */* ]]; then
			die "$child: invalid name"
		fi
		[[ -n ${seen["$name"]} ]] && die "$child: duplicate name"
		seen["$name"]=1
		skip_ws
		[[ ${raw:p:1} == ':' ]] || die "invalid JSON at byte $p: expected ':'"
		(( p++ ))
		parse_value "$child"
		skip_ws
		case ${raw:p:1} in
		',') (( p++ )) ;;
		'}') (( p++ )); return ;;
		*) die "invalid JSON at byte $p: expected ',' or '}'" ;;
		esac
	done
}

# ---------------------------------------------------------------- file system
function write_file {   # write_file <k> <path>: parts of entry k joined with NUL bytes
	integer k=$1 j
	{
		print -rn -- "${PART["$k,0"]}"
		for (( j = 1; j < NP[k]; j++ )); do
			printf '\0'
			print -rn -- "${PART["$k,$j"]}"
		done
	} > "$2" || die "$2: cannot write file"
}

function apply {
	integer k
	typeset f
	for (( k = 0; k < ${#KIND[@]}; k++ )); do
		f=./${PATHS[k]}
		# lstat-like: a symlink is never followed
		if [[ -L $f ]]; then
			rm -f -- "$f" || die "$f: cannot remove"
		elif [[ -d $f ]]; then
			[[ ${KIND[k]} == d ]] && continue
			die "$f: a directory is in the way"
		elif [[ -e $f ]]; then
			rm -f -- "$f" || die "$f: cannot remove"
		fi
		case ${KIND[k]} in
		d) mkdir -- "$f" || die "$f: cannot create directory" ;;
		f) write_file $k "$f" ;;
		x)
			write_file $k "$f"
			chmod a+x "$f" || die "$f: cannot chmod"
			;;
		l) ln -s -- "${PART["$k,0"]}" "$f" || die "$f: cannot create symbolic link" ;;
		esac
	done
}

# ---------------------------------------------------------------- main
if (( $# > 0 )); then
	print -ru2 -- "usage: json2dir < document.json"
	exit 2
fi

# read -d '' splits at NUL bytes: any NUL in the input makes it invalid JSON
# (outside strings it is not whitespace, inside strings it is an unescaped control character).
raw=
while IFS= read -r -d '' c; do
	die "invalid JSON: NUL byte in input"
done
raw=$c
n=${#raw}
p=0
[[ ${raw:0:3} == $'\xEF\xBB\xBF' ]] && p=3   # a leading BOM is ignored, as §3 allows

skip_ws
[[ ${raw:p:1} == '{' ]] || die "the root of the document must be an object"
parse_object .
skip_ws
(( p < n )) && die "invalid JSON at byte $p: trailing data"

apply
exit 0
