package main

// Vista previa de enlaces (10 nov 2026). La app de WhatsApp arma la tarjeta
// (imagen, título, dominio) en el teléfono de quien envía; un mensaje que sale
// del bridge como Conversation llega como texto plano con el enlace pelado.
// Aquí se hace lo mismo que la app: se baja la página, se toman título,
// descripción e imagen (og:* y, si faltan, <title>, meta description y el
// apple-touch-icon / icon), y se manda un ExtendedTextMessage con la miniatura.
// Si algo falla, el mensaje sale igual como texto plano.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"html"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	waProto "go.mau.fi/whatsmeow/binary/proto"
	"google.golang.org/protobuf/proto"
)

var (
	reURL      = regexp.MustCompile(`https?://[^\s<>"']+`)
	reMetaTag  = regexp.MustCompile(`(?is)<meta\s[^>]*>`)
	reLinkTag  = regexp.MustCompile(`(?is)<link\s[^>]*>`)
	reTitleTag = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	reAttr     = regexp.MustCompile(`(?is)([a-z:_-]+)\s*=\s*("([^"]*)"|'([^']*)')`)
)

const previewUA = "WhatsApp/2.24.20 A"

// Solo direcciones públicas: el enlace de un mensaje no debe poder hacer que el
// bridge consulte la red local, el propio localhost:8080 ni la metadata de la
// nube. Se revisa la IP ya resuelta (cubre DNS rebinding) y cada redirección.
func ipPermitida(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() ||
		ip.IsInterfaceLocalMulticast() || ip.Equal(net.IPv4bcast) ||
		// 100.64.0.0/10 (CGNAT) y 0.0.0.0/8
		(ip.To4() != nil && (ip.To4()[0] == 0 || (ip.To4()[0] == 100 && ip.To4()[1]&0xC0 == 64))))
}

func urlPermitida(u *url.URL) error {
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("esquema no permitido")
	}
	if p := u.Port(); p != "" && p != "80" && p != "443" {
		return errors.New("puerto no permitido")
	}
	return nil
}

var previewClient = &http.Client{
	Timeout: 10 * time.Second,
	Transport: &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
			if err != nil {
				return nil, err
			}
			for _, ip := range ips {
				if ipPermitida(ip) {
					var d net.Dialer
					return d.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
				}
			}
			return nil, fmt.Errorf("dirección no permitida: %s", host)
		},
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 8 * time.Second,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("demasiadas redirecciones")
		}
		return urlPermitida(req.URL)
	},
}

const maxPixeles = 25_000_000

type linkPreview struct {
	URL, Title, Description string
	Thumb                   []byte
	W, H                    uint32
}

func attrs(tag string) map[string]string {
	m := map[string]string{}
	for _, a := range reAttr.FindAllStringSubmatch(tag, -1) {
		v := a[3]
		if v == "" {
			v = a[4]
		}
		m[strings.ToLower(a[1])] = html.UnescapeString(strings.TrimSpace(v))
	}
	return m
}

func httpGet(ctx context.Context, u string, limit int64) ([]byte, string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, "", err
	}
	if err := urlPermitida(req.URL); err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", previewUA)
	req.Header.Set("Accept-Language", "es")
	resp, err := previewClient.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, "", io.ErrUnexpectedEOF
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	return b, resp.Request.URL.String(), err
}

// fetchLinkPreview devuelve nil si la página no da al menos un título.
func fetchLinkPreview(rawURL string) *linkPreview {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body, finalURL, err := httpGet(ctx, rawURL, 2<<20)
	if err != nil {
		return nil
	}
	page := string(body)
	if i := strings.Index(strings.ToLower(page), "</head>"); i > 0 {
		page = page[:i]
	}

	meta := map[string]string{}
	for _, t := range reMetaTag.FindAllString(page, -1) {
		a := attrs(t)
		key := a["property"]
		if key == "" {
			key = a["name"]
		}
		key = strings.ToLower(key)
		if key != "" && a["content"] != "" {
			if _, ok := meta[key]; !ok {
				meta[key] = a["content"]
			}
		}
	}

	p := &linkPreview{URL: rawURL}
	p.Title = firstNonEmpty(meta["og:title"], meta["twitter:title"])
	if p.Title == "" {
		if m := reTitleTag.FindStringSubmatch(page); m != nil {
			p.Title = html.UnescapeString(strings.TrimSpace(m[1]))
		}
	}
	if p.Title == "" {
		return nil
	}
	p.Description = firstNonEmpty(meta["og:description"], meta["twitter:description"], meta["description"])

	img := firstNonEmpty(meta["og:image"], meta["og:image:url"], meta["twitter:image"])
	if img == "" {
		// Igual que la app: a falta de og:image, el ícono del sitio.
		var icon string
		for _, t := range reLinkTag.FindAllString(page, -1) {
			a := attrs(t)
			rel := strings.ToLower(a["rel"])
			if strings.Contains(rel, "apple-touch-icon") && a["href"] != "" {
				img = a["href"]
				break
			}
			if icon == "" && strings.Contains(rel, "icon") && a["href"] != "" {
				icon = a["href"]
			}
		}
		if img == "" {
			img = icon
		}
	}
	if img != "" {
		if base, err := url.Parse(finalURL); err == nil {
			if ref, err := url.Parse(img); err == nil {
				img = base.ResolveReference(ref).String()
			}
		}
		if data, _, err := httpGet(ctx, img, 8<<20); err == nil {
			p.Thumb, p.W, p.H = makeThumb(data, 300)
		}
	}
	return p
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}

// makeThumb reduce la imagen (lado mayor <= max) promediando píxeles, la pone
// sobre fondo blanco (los PNG con transparencia salen negros en JPEG) y la
// devuelve en JPEG.
func makeThumb(data []byte, max int) (thumb []byte, w uint32, h uint32) {
	defer func() {
		if recover() != nil {
			thumb, w, h = nil, 0, 0
		}
	}()
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width*cfg.Height > maxPixeles {
		return nil, 0, 0
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0
	}
	b := src.Bounds()
	sw, sh := b.Dx(), b.Dy()
	if sw == 0 || sh == 0 {
		return nil, 0, 0
	}
	dw, dh := sw, sh
	if sw > max || sh > max {
		if sw >= sh {
			dw, dh = max, sh*max/sw
		} else {
			dw, dh = sw*max/sh, max
		}
	}
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		y0, y1 := y*sh/dh, (y+1)*sh/dh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < dw; x++ {
			x0, x1 := x*sw/dw, (x+1)*sw/dw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, n uint32
			for yy := y0; yy < y1; yy++ {
				for xx := x0; xx < x1; xx++ {
					// Sobre fondo blanco: color premultiplicado + blanco*(1-alfa).
					pr, pg, pb, pa := src.At(b.Min.X+xx, b.Min.Y+yy).RGBA()
					r += (pr + (0xffff - pa)) >> 8
					g += (pg + (0xffff - pa)) >> 8
					bl += (pb + (0xffff - pa)) >> 8
					n++
				}
			}
			o := dst.PixOffset(x, y)
			dst.Pix[o], dst.Pix[o+1], dst.Pix[o+2], dst.Pix[o+3] = uint8(r/n), uint8(g/n), uint8(bl/n), 255
		}
	}
	var out bytes.Buffer
	if err := jpeg.Encode(&out, dst, &jpeg.Options{Quality: 80}); err != nil {
		return nil, 0, 0
	}
	return out.Bytes(), uint32(dw), uint32(dh)
}

// textMessageWithPreview arma el mensaje de texto; si trae un enlace con
// vista previa disponible, sale como ExtendedTextMessage con la tarjeta.
func textMessageWithPreview(message string) *waProto.Message {
	link := reURL.FindString(message)
	link = strings.TrimRight(link, ".,;:!?)»”")
	if link == "" {
		return &waProto.Message{Conversation: proto.String(message)}
	}
	var p *linkPreview
	func() {
		defer func() { recover() }()
		p = fetchLinkPreview(link)
	}()
	if p == nil {
		return &waProto.Message{ExtendedTextMessage: &waProto.ExtendedTextMessage{
			Text: proto.String(message), MatchedText: proto.String(link),
		}}
	}
	ext := &waProto.ExtendedTextMessage{
		Text:        proto.String(message),
		MatchedText: proto.String(link),
		Title:       proto.String(p.Title),
		PreviewType: waProto.ExtendedTextMessage_NONE.Enum(),
	}
	if p.Description != "" {
		ext.Description = proto.String(p.Description)
	}
	if len(p.Thumb) > 0 {
		ext.JPEGThumbnail = p.Thumb
		ext.ThumbnailWidth = proto.Uint32(p.W)
		ext.ThumbnailHeight = proto.Uint32(p.H)
	}
	return &waProto.Message{ExtendedTextMessage: ext}
}
