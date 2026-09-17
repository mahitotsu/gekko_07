// analyst-attribute-serviceの本実装(ADR 0007:Go標準ライブラリ)。
//
// ADR 0009 §2の3つの多層防御(loopback限定bind・接続元loopback再チェック・合言葉ヘッダー検証)を
// k8s/analyst-attribute-service/app-configmap.yamlのスタブから引き継ぐ。テスト時だけ迂回する
// フラグは作らない(CWE-489)。
//
// 委任チェーンの終端(表3)。account-serviceからのみ呼ばれ、アナリストの業務属性
// (担当地域・権限レベル)を返す。正典は本サービスのデータベースであり、Keycloakのトークンには
// 一切含めない(ADR 0006:役割・オーナーシップ・機密性の3軸で「外部化すべき」側)。
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// regionsはPostgresのtext[]型で保持する。ADR 0007のGo標準ライブラリ方針を維持するため、
// 配列パース専用ライブラリ(lib/pq等)を追加せず、この内部フォーマット
// (`{tokyo,osaka}`、値はいずれも英数字のみの内部コードでカンマ・波括弧を含まない)専用の
// 最小限のsql.Scannerを自前で書く。
type stringArray []string

func (a *stringArray) Scan(src any) error {
	if src == nil {
		*a = nil
		return nil
	}
	var raw string
	switch v := src.(type) {
	case string:
		raw = v
	case []byte:
		raw = string(v)
	default:
		return fmt.Errorf("unsupported type for stringArray: %T", src)
	}
	raw = strings.TrimPrefix(raw, "{")
	raw = strings.TrimSuffix(raw, "}")
	if raw == "" {
		*a = stringArray{}
		return nil
	}
	*a = strings.Split(raw, ",")
	return nil
}

type analyst struct {
	ID      string   `json:"analystId"`
	Regions []string `json:"regions"`
	Level   string   `json:"level"`
}

func main() {
	db, err := openDB()
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := initSchema(db); err != nil {
		log.Fatalf("failed to initialize schema: %v", err)
	}

	handshakeFile := getenv("HANDSHAKE_TOKEN_FILE", "/handshake/token")
	handshakeHeader := getenv("HANDSHAKE_HEADER_NAME", "x-gekko-handshake")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /analysts/{sub}", handleGetAnalyst(db))

	handler := withHandshakeCheck(handshakeFile, handshakeHeader, withLoopbackCheck(mux))

	bindHost := getenv("APP_BIND_HOST", "127.0.0.1")
	bindPort := getenv("APP_PORT", "9000")
	addr := net.JoinHostPort(bindHost, bindPort)

	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("analyst-attribute-service listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

func openDB() (*sql.DB, error) {
	host := getenv("DB_HOST", "postgres")
	port := getenv("DB_PORT", "5432")
	name := mustGetenv("DB_NAME")
	user := mustGetenv("DB_USER")
	password := mustGetenv("DB_PASSWORD")

	dsn := fmt.Sprintf("host=%s port=%s dbname=%s user=%s password=%s sslmode=disable",
		host, port, name, user, password)
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for {
		if err := db.PingContext(ctx); err == nil {
			return db, nil
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("timed out waiting for database: %w", ctx.Err())
		case <-time.After(1 * time.Second):
		}
	}
}

// スキーマはこのアプリ自身が起動時に用意する(ADR 0007のGo標準ライブラリ方針を優先し、
// Flyway等のマイグレーションフレームワークは導入しない)。データ投入はしない
// (テストデータはk8s/analyst-attribute-service/seed-job.yamlが担当。account-serviceの
// Flyway seedとは異なり、KeycloakのユーザーID(sub)確定後でないと投入できないため)。
func initSchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS analysts (
			id      TEXT PRIMARY KEY,
			regions TEXT[] NOT NULL,
			level   TEXT NOT NULL CHECK (level IN ('junior', 'senior'))
		)
	`)
	return err
}

func handleGetAnalyst(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		pathSub := r.PathValue("sub")
		// ADR 0006:analyst:readスコープは既にEnvoy rbacで検証済み(k8s/analyst-attribute-service/
		// envoy-configmap.yaml)。ここでの追加チェックは「呼び出し元(account-service)が委任元と
		// 別人の属性を覗き見できないか」という業務データレベルの防御であり、Envoyのscope検証とは
		// 別の関心事。x-auth-subは委任チェーン全体でアナリスト本人のまま維持される(表1)ため、
		// 一致しなければ不正な参照とみなしfail closeする。
		authSub := r.Header.Get("x-auth-sub")
		if authSub == "" || authSub != pathSub {
			http.NotFound(w, r)
			return
		}

		var regions stringArray
		var level string
		err := db.QueryRowContext(r.Context(),
			`SELECT regions, level FROM analysts WHERE id = $1`, pathSub,
		).Scan(&regions, &level)
		if errors.Is(err, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			log.Printf("query failed: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		writeJSON(w, http.StatusOK, analyst{ID: pathSub, Regions: []string(regions), Level: level})
	}
}

// ADR 0009 主対策②:bindアドレスの設定に関係なく、接続元がloopbackでなければ拒否する。
func withLoopbackCheck(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !isLoopback(host) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isLoopback(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// ADR 0009 §2③:rbac通過後にのみEnvoyのLuaフィルタが合言葉ヘッダーを付与する。
// 欠落・不一致はどちらも同じfail closeとして扱い、検証をバイパスするフラグは持たない(CWE-489)。
func withHandshakeCheck(handshakeFile, headerName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expected, err := os.ReadFile(handshakeFile)
		got := r.Header.Get(headerName)
		if err != nil || got == "" || strings.TrimSpace(string(expected)) != got {
			http.Error(w, "handshake verification failed", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func mustGetenv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("missing required environment variable %s", key)
	}
	return v
}
