package main

import (
	"context"
	"errors"
	stdlog "log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"dynatrace.com/easytrade/aggregator-service/clock"
	"dynatrace.com/easytrade/aggregator-service/config"
	"dynatrace.com/easytrade/aggregator-service/datagenerator"
	"dynatrace.com/easytrade/aggregator-service/logger"
	"dynatrace.com/easytrade/aggregator-service/offer"
	"dynatrace.com/easytrade/aggregator-service/platform"
	"dynatrace.com/easytrade/aggregator-service/signup"
	"dynatrace.com/easytrade/aggregator-service/telemetry"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const serviceName = "aggregator-service"

const xmlProbability = 0.5

func main() {
	// Telemetry first: the logger built below bridges into the OpenTelemetry logger provider.
	shutdownTelemetry, err := telemetry.Setup(context.Background(), serviceName)
	if err != nil {
		// Run without telemetry rather than not at all.
		stdlog.Printf("Failed to set up OpenTelemetry, continuing without it: %v", err)
		shutdownTelemetry = func(context.Context) error { return nil }
	}
	go flushTelemetryOnSignal(shutdownTelemetry)
	// Client spans and W3C trace context on every request to offerservice.
	http.DefaultClient.Transport = otelhttp.NewTransport(http.DefaultTransport)

	l := logger.GetSugar()
	defer l.Sync()

	c, err := config.LoadConfig()
	if err != nil {
		l.Fatal("Configuration loading failed")
	}

	wg := sync.WaitGroup{}
	offerProvider := offer.OfferServiceConnector{OfferServiceConfig: c.OfferServiceConfig}
	signupHandler := signup.OfferServiceSignupHandler{OfferServiceConfig: c.OfferServiceConfig}
	for _, pc := range c.PlatformConfigs {
		p := platform.Platform{
			OfferProvider:  &offerProvider,
			SignupHandler:  &signupHandler,
			PlatformConfig: pc.PlatformConfig,
		}

		l.Infow("Starting clocks", "checkOffersInterval", p.Delay, "signupInterval", p.SignupInterval)

		clock.NewBlockingClock(p.Delay, func() { checkOffersTick(&p) }, &wg).Start()
		clock.NewBlockingClock(p.SignupInterval, func() { signupTick(&p, &pc.PackageProbability) }, &wg).Start()
	}

	wg.Wait()
}

// flushTelemetryOnSignal exports the buffered telemetry when the pod is stopped.
func flushTelemetryOnSignal(shutdown func(context.Context) error) {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := shutdown(shutdownCtx); err != nil {
		stdlog.Print(err)
	}
	os.Exit(0)
}

func checkOffersTick(p *platform.Platform) {
	l := logger.GetSugar().Named(p.Name)
	l.Info("Checking the offers...")

	useXml := rand.Float32() > xmlProbability
	offer, err := p.CheckOffers(useXml)
	if err != nil {
		l.Error("Checking the offers failed")
	} else {
		l.Infow("Offers checked", "offer", offer)
	}

	if errors.Is(err, platform.ErrFailCounterLimitExceeded) {
		l.Warnw("Pausing the platform", "failDelay", p.FailDelay)
		time.Sleep(p.FailDelay)
	}
}

func signupTick(p *platform.Platform, packageProb *config.PackageProbability) {
	l := logger.GetSugar().Named(p.Name)
	l.Info("Signing up a user...")

	sr := datagenerator.CreateFakeSignupRequest(p.Name, packageProb)

	err := p.Signup(sr)
	if err != nil {
		l.Error("Signing up a user failed")
	} else {
		l.Info("User signed up")
	}
}
