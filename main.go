package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type obj = map[string]any

var networkAliases = map[string]string{
	"raw":       "tcp",
	"mkcp":      "kcp",
	"splithttp": "xhttp",
	"h2":        "http",
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9_.-]+`)

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }

func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

type result struct {
	remark string
	data   obj
	uri    string
}

func newMux() obj {
	return obj{
		"concurrency":     -1,
		"enabled":         false,
		"xudpConcurrency": 8,
		"xudpProxyUDP443": "",
	}
}

func orDefault(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

func b64decode(value string) (string, error) {
	value = strings.TrimSpace(value)
	value = strings.NewReplacer("-", "+", "_", "/").Replace(value)
	value = strings.TrimRight(value, "=")
	raw, err := base64.RawStdEncoding.DecodeString(value)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func unq(value string) string {
	if decoded, err := url.PathUnescape(value); err == nil {
		return decoded
	}
	return value
}

func parseQuery(raw string) map[string]string {
	result := map[string]string{}
	for _, pair := range strings.Split(raw, "&") {
		if pair == "" {
			continue
		}
		key, value, _ := strings.Cut(pair, "=")
		result[unq(key)] = unq(value)
	}
	return result
}

func splitHostPort(hostport string) (string, int, error) {
	hostport = strings.TrimRight(strings.TrimSpace(hostport), "/")
	host, portText, err := net.SplitHostPort(hostport)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return "", 0, err
	}
	return host, port, nil
}

func splitList(value string) []string {
	items := []string{}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			items = append(items, item)
		}
	}
	return items
}

func truthy(value string) bool {
	switch strings.ToLower(value) {
	case "1", "true", "yes":
		return true
	}
	return false
}

func str(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return ""
}

func endpoint(u *url.URL) (string, int, error) {
	host := u.Hostname()
	if host == "" {
		return "", 0, errors.New("missing host")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		return "", 0, errors.New("missing or invalid port")
	}
	return host, port, nil
}

func buildStream(p map[string]string, defaultSecurity string) obj {
	network := orDefault(p["type"], "tcp")
	if alias, ok := networkAliases[network]; ok {
		network = alias
	}
	security := orDefault(p["security"], defaultSecurity)
	stream := obj{"network": network}

	switch network {
	case "tcp":
		headerType := orDefault(p["headerType"], "none")
		header := obj{"type": headerType}
		if headerType == "http" {
			request := obj{"path": splitList(orDefault(p["path"], "/"))}
			if p["host"] != "" {
				request["headers"] = obj{"Host": splitList(p["host"])}
			}
			header["request"] = request
		}
		stream["tcpSettings"] = obj{"header": header}
	case "ws":
		ws := obj{"path": orDefault(p["path"], "/")}
		if p["host"] != "" {
			ws["headers"] = obj{"Host": p["host"]}
		}
		stream["wsSettings"] = ws
	case "grpc":
		grpc := obj{
			"serviceName": orDefault(p["serviceName"], p["path"]),
			"multiMode":   p["mode"] == "multi",
		}
		if p["authority"] != "" {
			grpc["authority"] = p["authority"]
		}
		stream["grpcSettings"] = grpc
	case "kcp":
		kcp := obj{"header": obj{"type": orDefault(p["headerType"], "none")}}
		if p["seed"] != "" {
			kcp["seed"] = p["seed"]
		}
		stream["kcpSettings"] = kcp
	case "httpupgrade":
		hu := obj{"path": orDefault(p["path"], "/")}
		if p["host"] != "" {
			hu["host"] = p["host"]
		}
		stream["httpupgradeSettings"] = hu
	case "xhttp":
		xh := obj{"path": orDefault(p["path"], "/")}
		if p["host"] != "" {
			xh["host"] = p["host"]
		}
		if p["mode"] != "" {
			xh["mode"] = p["mode"]
		}
		if p["extra"] != "" {
			var extra any
			if json.Unmarshal([]byte(p["extra"]), &extra) == nil {
				xh["extra"] = extra
			}
		}
		stream["xhttpSettings"] = xh
	case "http":
		h := obj{"path": orDefault(p["path"], "/")}
		if p["host"] != "" {
			h["host"] = splitList(p["host"])
		}
		stream["httpSettings"] = h
	}

	stream["security"] = security

	switch security {
	case "tls":
		tls := obj{
			"serverName":  orDefault(p["sni"], orDefault(p["host"], p["address"])),
			"fingerprint": orDefault(p["fp"], "chrome"),
		}
		if p["alpn"] != "" {
			tls["alpn"] = splitList(p["alpn"])
		}
		if truthy(p["allowInsecure"]) || truthy(p["insecure"]) {
			tls["allowInsecure"] = true
		}
		if p["ech"] != "" {
			tls["echConfigList"] = p["ech"]
		}
		stream["tlsSettings"] = tls
	case "reality":
		reality := obj{
			"fingerprint": orDefault(p["fp"], "chrome"),
			"publicKey":   p["pbk"],
			"serverName":  p["sni"],
			"shortId":     p["sid"],
			"show":        false,
			"spiderX":     p["spx"],
		}
		if p["pqv"] != "" {
			reality["mldsa65Verify"] = p["pqv"]
		}
		stream["realitySettings"] = reality
	}

	if p["fm"] != "" {
		var finalmask any
		if json.Unmarshal([]byte(p["fm"]), &finalmask) == nil {
			stream["finalmask"] = finalmask
		}
	}

	return stream
}

func parseSS(uri string) (string, obj, error) {
	body := strings.TrimPrefix(uri, "ss://")
	body, fragment, _ := strings.Cut(body, "#")
	body, _, _ = strings.Cut(body, "?")
	remark := unq(fragment)

	var credentials, hostport string
	if at := strings.LastIndex(body, "@"); at >= 0 {
		userinfo := body[:at]
		hostport = body[at+1:]
		decoded, err := b64decode(userinfo)
		if err == nil && strings.Contains(decoded, ":") {
			credentials = decoded
		} else {
			credentials = unq(userinfo)
		}
	} else {
		decoded, err := b64decode(strings.TrimRight(body, "/"))
		if err != nil {
			return "", nil, err
		}
		at := strings.LastIndex(decoded, "@")
		if at < 0 {
			return "", nil, errors.New("invalid shadowsocks uri")
		}
		credentials = decoded[:at]
		hostport = decoded[at+1:]
	}

	method, password, _ := strings.Cut(credentials, ":")
	host, port, err := splitHostPort(hostport)
	if err != nil {
		return "", nil, err
	}

	outbound := obj{
		"mux":      newMux(),
		"protocol": "shadowsocks",
		"settings": obj{
			"servers": []any{
				obj{
					"address":  host,
					"level":    1,
					"method":   method,
					"ota":      false,
					"password": password,
					"port":     port,
				},
			},
		},
		"streamSettings": obj{"network": "tcp"},
		"tag":            "proxy",
	}
	return remark, outbound, nil
}

func parseVLESS(uri string) (string, obj, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return "", nil, err
	}
	host, port, err := endpoint(u)
	if err != nil {
		return "", nil, err
	}
	q := parseQuery(u.RawQuery)
	q["address"] = host

	settings := obj{
		"address":    host,
		"encryption": orDefault(q["encryption"], "none"),
		"id":         u.User.Username(),
		"level":      8,
		"port":       port,
		"security":   "auto",
	}
	if q["flow"] != "" {
		settings["flow"] = q["flow"]
	}

	outbound := obj{
		"mux":            newMux(),
		"protocol":       "vless",
		"settings":       settings,
		"streamSettings": buildStream(q, "none"),
		"tag":            "proxy",
	}
	return u.Fragment, outbound, nil
}

func parseVMess(uri string) (string, obj, error) {
	raw, err := b64decode(strings.TrimPrefix(uri, "vmess://"))
	if err != nil {
		return "", nil, err
	}
	data := map[string]any{}
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return "", nil, err
	}

	host := str(data["add"])
	if host == "" {
		return "", nil, errors.New("missing host")
	}
	port, err := strconv.Atoi(str(data["port"]))
	if err != nil {
		return "", nil, errors.New("missing or invalid port")
	}
	aid, _ := strconv.Atoi(str(data["aid"]))

	mode := ""
	if str(data["type"]) == "multi" {
		mode = "multi"
	}
	p := map[string]string{
		"address":     host,
		"type":        orDefault(str(data["net"]), "tcp"),
		"headerType":  orDefault(str(data["type"]), "none"),
		"host":        str(data["host"]),
		"path":        str(data["path"]),
		"security":    orDefault(str(data["tls"]), "none"),
		"sni":         str(data["sni"]),
		"alpn":        str(data["alpn"]),
		"fp":          str(data["fp"]),
		"serviceName": str(data["path"]),
		"mode":        mode,
		"authority":   str(data["authority"]),
	}

	settings := obj{
		"address":    host,
		"alterId":    aid,
		"encryption": "",
		"flow":       "",
		"id":         str(data["id"]),
		"level":      8,
		"port":       port,
		"security":   orDefault(str(data["scy"]), "auto"),
	}

	outbound := obj{
		"mux":            newMux(),
		"protocol":       "vmess",
		"settings":       settings,
		"streamSettings": buildStream(p, "none"),
		"tag":            "proxy",
	}
	return str(data["ps"]), outbound, nil
}

func parseTrojan(uri string) (string, obj, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return "", nil, err
	}
	host, port, err := endpoint(u)
	if err != nil {
		return "", nil, err
	}
	q := parseQuery(u.RawQuery)
	q["address"] = host

	outbound := obj{
		"mux":      newMux(),
		"protocol": "trojan",
		"settings": obj{
			"address":  host,
			"level":    8,
			"password": u.User.Username(),
			"port":     port,
		},
		"streamSettings": buildStream(q, "tls"),
		"tag":            "proxy",
	}
	return u.Fragment, outbound, nil
}

var parsers = map[string]func(string) (string, obj, error){
	"ss":     parseSS,
	"vless":  parseVLESS,
	"vmess":  parseVMess,
	"trojan": parseTrojan,
}

func buildConfig(remark string, outbound obj) obj {
	sniffing := func() obj {
		return obj{
			"destOverride": []any{"http", "tls", "quic"},
			"enabled":      true,
		}
	}
	return obj{
		"dns": obj{
			"hosts":         obj{"domain:googleapis.cn": "googleapis.com"},
			"queryStrategy": "UseIPv4",
			"servers": []any{
				"1.1.1.1",
				obj{"address": "1.1.1.1", "domains": []any{}, "port": 53},
				obj{"address": "8.8.8.8", "domains": []any{}, "port": 53},
			},
		},
		"inbounds": []any{
			obj{
				"listen":   "127.0.0.1",
				"port":     10808,
				"protocol": "socks",
				"settings": obj{"auth": "noauth", "udp": true, "userLevel": 8},
				"sniffing": sniffing(),
				"tag":      "socks",
			},
			obj{
				"listen":   "127.0.0.1",
				"port":     10809,
				"protocol": "http",
				"settings": obj{"userLevel": 8},
				"sniffing": sniffing(),
				"tag":      "http",
			},
			obj{
				"listen":   "127.0.0.1",
				"port":     11111,
				"protocol": "dokodemo-door",
				"settings": obj{"address": "127.0.0.1"},
				"tag":      "metrics_in",
			},
		},
		"log":     obj{"loglevel": "warning"},
		"metrics": obj{"tag": "metrics_out"},
		"outbounds": []any{
			outbound,
			obj{
				"protocol": "freedom",
				"settings": obj{"domainStrategy": "UseIP"},
				"tag":      "direct",
			},
			obj{
				"protocol": "blackhole",
				"settings": obj{"response": obj{"type": "http"}},
				"tag":      "block",
			},
		},
		"policy": obj{
			"levels": obj{
				"0": obj{"statsUserDownlink": true, "statsUserUplink": true},
				"8": obj{
					"connIdle":     300,
					"downlinkOnly": 1,
					"handshake":    4,
					"uplinkOnly":   1,
				},
			},
			"system": obj{
				"statsInboundDownlink":  true,
				"statsInboundUplink":    true,
				"statsOutboundDownlink": true,
				"statsOutboundUplink":   true,
			},
		},
		"remarks": remark,
		"routing": obj{
			"domainStrategy": "IPIfNonMatch",
			"rules": []any{
				obj{"inboundTag": []any{"metrics_in"}, "outboundTag": "metrics_out"},
				obj{"inboundTag": []any{"socks"}, "outboundTag": "proxy", "port": "53"},
				obj{"ip": []any{"1.1.1.1"}, "outboundTag": "proxy", "port": "53"},
				obj{"ip": []any{"8.8.8.8"}, "outboundTag": "direct", "port": "53"},
			},
		},
		"stats": obj{},
	}
}

func convert(uri string, outboundOnly bool) (string, obj, error) {
	uri = strings.TrimSpace(uri)
	scheme, _, found := strings.Cut(uri, "://")
	if !found {
		return "", nil, errors.New("not a uri")
	}
	parser, ok := parsers[strings.ToLower(scheme)]
	if !ok {
		return "", nil, fmt.Errorf("unsupported scheme: %s", scheme)
	}
	remark, outbound, err := parser(uri)
	if err != nil {
		return "", nil, err
	}
	if outboundOnly {
		return remark, outbound, nil
	}
	return remark, buildConfig(remark, outbound), nil
}

func collectURIs(args []string, inputs []string) ([]string, error) {
	lines := append([]string{}, args...)
	for _, path := range inputs {
		content, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		lines = append(lines, strings.Split(string(content), "\n")...)
	}
	if len(lines) == 0 {
		if info, err := os.Stdin.Stat(); err == nil && info.Mode()&os.ModeCharDevice == 0 {
			content, err := io.ReadAll(os.Stdin)
			if err != nil {
				return nil, err
			}
			lines = append(lines, strings.Split(string(content), "\n")...)
		}
	}
	uris := []string{}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "://") {
			uris = append(uris, line)
		}
	}
	return uris, nil
}

func fileName(remark, uri string) string {
	cleaned := strings.Trim(unsafeName.ReplaceAllString(remark, "_"), "_")
	if cleaned == "" {
		cleaned = "config"
	}
	sum := sha1.Sum([]byte(uri))
	return fmt.Sprintf("%s_%s.json", cleaned, hex.EncodeToString(sum[:4]))
}

func encode(value any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "    ")
	if err := enc.Encode(value); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func main() {
	var inputs stringList
	var outDir string
	var outboundOnly bool

	flag.Var(&inputs, "i", "file with URIs, one per line (repeatable)")
	flag.StringVar(&outDir, "o", "", "output directory, one JSON file per URI")
	flag.BoolVar(&outboundOnly, "outbound-only", false, "emit only the outbound object")
	flag.Parse()

	uris, err := collectURIs(flag.Args(), inputs)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if len(uris) == 0 {
		fmt.Fprintln(os.Stderr, "no URIs provided")
		flag.Usage()
		os.Exit(2)
	}

	results := []result{}
	failed := false
	for i, uri := range uris {
		remark, data, err := convert(uri, outboundOnly)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[%d] failed: %v\n", i+1, err)
			failed = true
			continue
		}
		results = append(results, result{remark: remark, data: data, uri: uri})
	}

	if outDir != "" {
		if err := os.MkdirAll(outDir, 0o700); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, r := range results {
			encoded, err := encode(r.data)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				failed = true
				continue
			}
			target := filepath.Join(outDir, fileName(r.remark, r.uri))
			if err := os.WriteFile(target, encoded, 0o600); err != nil {
				fmt.Fprintln(os.Stderr, err)
				failed = true
				continue
			}
			fmt.Println(target)
		}
	} else if len(results) > 0 {
		var payload any
		if len(results) == 1 {
			payload = results[0].data
		} else {
			items := make([]any, len(results))
			for i, r := range results {
				items[i] = r.data
			}
			payload = items
		}
		encoded, err := encode(payload)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Stdout.Write(encoded)
	}

	if failed {
		os.Exit(1)
	}
}
