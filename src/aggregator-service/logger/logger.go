package logger

import (
	"os"
	"sync"

	"go.opentelemetry.io/contrib/bridges/otelzap"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"golang.org/x/term"
)

var (
	logger *zap.Logger
	once   sync.Once
)

func Get() *zap.Logger {
	once.Do(func() {
		config := zap.NewProductionConfig()
		if term.IsTerminal(int(os.Stdout.Fd())) {
			config = zap.NewDevelopmentConfig()
		}
		config.DisableStacktrace = true

		// Every record also goes to the OpenTelemetry logger provider.
		logger = zap.Must(config.Build(zap.WrapCore(func(core zapcore.Core) zapcore.Core {
			return zapcore.NewTee(core, otelzap.NewCore("aggregator-service"))
		})))
	})
	return logger
}

func GetSugar() *zap.SugaredLogger {
	return Get().Sugar()
}
