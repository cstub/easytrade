package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"dynatrace.com/easytrade/pricing-service/services"
	"dynatrace.com/easytrade/pricing-service/telemetry"
	"dynatrace.com/easytrade/pricing-service/utils"
	log "github.com/sirupsen/logrus"
	"go.opentelemetry.io/contrib/bridges/otellogrus"
)

const serviceName = "pricing-service"

var shutdownTelemetry func(context.Context) error

func init() {
	if _, ok := os.LookupEnv(utils.GinMode); !ok {
		utils.LoadLocalEnv()
	}

	utils.CheckEnv()

	var err error
	shutdownTelemetry, err = telemetry.Setup(context.Background(), serviceName)
	if err != nil {
		log.Fatalf("Failed to set up OpenTelemetry: %v", err)
	}
	log.AddHook(otellogrus.NewHook(serviceName))

	services.ConnectToDB()
}

//	@title			Pricing service API
//	@version		1.0
//	@description	This service provides information about the prices of instruments being handled by easyTrade.
//	@termsOfService	http://swagger.io/terms/

//	@license.name	Apache 2.0
//	@license.url	http://www.apache.org/licenses/LICENSE-2.0.html

// @schemes	http
func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	server := &http.Server{Addr: listenAddress(), Handler: CreateRouter()}
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()

	// Flush the telemetry still buffered when the pod is stopped.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Error(err)
	}
	if err := shutdownTelemetry(shutdownCtx); err != nil {
		log.Error(err)
	}
}

// listenAddress matches gin's Run(): $PORT if set, else 8080.
func listenAddress() string {
	if port, ok := os.LookupEnv("PORT"); ok {
		return ":" + port
	}
	return ":8080"
}
