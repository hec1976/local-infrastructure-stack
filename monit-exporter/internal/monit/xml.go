package monit

import (
	"encoding/xml"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Node is a lossless-enough XML tree for Monit's status document.  The exporter
// deliberately avoids a brittle version-specific struct: Monit adds metrics over
// time, and every numeric leaf remains exportable via monit_value.
type Node struct {
	XMLName  xml.Name
	Attr     []xml.Attr
	Text     string
	Children []*Node
}

func (n *Node) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	n.XMLName = start.Name
	n.Attr = append([]xml.Attr(nil), start.Attr...)
	var text strings.Builder
	for {
		tok, err := d.Token()
		if err != nil {
			if err == io.EOF {
				return io.ErrUnexpectedEOF
			}
			return err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			c := &Node{}
			if err := d.DecodeElement(c, &t); err != nil {
				return err
			}
			n.Children = append(n.Children, c)
		case xml.CharData:
			text.Write([]byte(t))
		case xml.EndElement:
			if t.Name == start.Name {
				n.Text = strings.TrimSpace(text.String())
				return nil
			}
		}
	}
}

func Parse(r io.Reader) (*Node, error) {
	dec := xml.NewDecoder(io.LimitReader(r, 16<<20))
	// Monit traditionally declares ISO-8859-1 in its XML status output.
	// Keep this dependency-free and translate Latin-1 bytes to UTF-8 runes.
	dec.CharsetReader = func(charset string, input io.Reader) (io.Reader, error) {
		cs := strings.ToLower(strings.TrimSpace(charset))
		if cs != "iso-8859-1" && cs != "latin1" && cs != "latin-1" {
			return nil, fmt.Errorf("unsupported XML charset %q", charset)
		}
		b, err := io.ReadAll(io.LimitReader(input, 16<<20))
		if err != nil {
			return nil, err
		}
		var out strings.Builder
		out.Grow(len(b))
		for _, c := range b {
			out.WriteRune(rune(c))
		}
		return strings.NewReader(out.String()), nil
	}
	var root Node
	if err := dec.Decode(&root); err != nil {
		return nil, fmt.Errorf("parse monit xml: %w", err)
	}
	if root.XMLName.Local != "monit" {
		return nil, fmt.Errorf("unexpected root element %q", root.XMLName.Local)
	}
	return &root, nil
}

func (n *Node) AttrValue(name string) string {
	for _, a := range n.Attr {
		if a.Name.Local == name {
			return a.Value
		}
	}
	return ""
}
func (n *Node) Child(name string) *Node {
	for _, c := range n.Children {
		if c.XMLName.Local == name {
			return c
		}
	}
	return nil
}
func (n *Node) ChildrenNamed(name string) []*Node {
	out := []*Node{}
	for _, c := range n.Children {
		if c.XMLName.Local == name {
			out = append(out, c)
		}
	}
	return out
}
func (n *Node) PathText(path ...string) string {
	cur := n
	for _, p := range path {
		if cur == nil {
			return ""
		}
		cur = cur.Child(p)
	}
	if cur == nil {
		return ""
	}
	return cur.Text
}
func Float(s string) (float64, bool) {
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return v, err == nil
}
func Int(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return v, err == nil
}

var ServiceTypes = map[string]string{
	"0": "filesystem", "1": "directory", "2": "file", "3": "process",
	"4": "host", "5": "system", "6": "fifo", "7": "program", "8": "network",
}

func ServiceType(code string) string {
	if s, ok := ServiceTypes[code]; ok {
		return s
	}
	if code == "" {
		return "unknown"
	}
	return "unknown_" + code
}

func Services(root *Node) []*Node { return root.ChildrenNamed("service") }
