package main

import (
	"fmt"
	"os"
	"time"

	"dynatrace.com/easytrade/pricing-service/docs"
	"dynatrace.com/easytrade/pricing-service/price"
	"dynatrace.com/easytrade/pricing-service/utils"
	"dynatrace.com/easytrade/pricing-service/version"
	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
)

func Logger() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		startTime := time.Now()

		ctx.Next()

		latency := time.Since(startTime)
		requestString := fmt.Sprintf("%s %s", ctx.Request.Method, ctx.Request.URL)

		log.WithContext(ctx.Request.Context()).WithFields(log.Fields{
			"request": requestString,
			"status":  ctx.Writer.Status(),
			"latency": latency,
			"ip":      ctx.ClientIP(),
		}).Info("Request finished")
	}
}

func CreateRouter() *gin.Engine {
	router := gin.New()

	router.Use(otelgin.Middleware(serviceName))
	router.Use(cors.Default())
	router.Use(gin.Recovery())
	router.Use(Logger())

	v1 := router.Group("/v1")
	{
		pricesRoute := v1.Group("/prices")
		{
			pricesRoute.GET("/latest", price.GetCurrentPrices)
			pricesRoute.GET("/last", price.GetLastPrice)
			pricesRoute.GET("/instrument/:instrumentId", price.GetPricingDataForInstrument)
		}
	}
	router.GET("/version", version.GetVersion)

	if value, ok := os.LookupEnv(utils.ProxyPrefix); ok {
		docs.SwaggerInfo.BasePath = "/" + value
	}

	url := ginSwagger.URL("swagger/doc.json")
	router.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler, url))

	return router
}
