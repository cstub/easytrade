package price

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"dynatrace.com/easytrade/pricing-service/services"
	"dynatrace.com/easytrade/pricing-service/utils"
	"github.com/gin-gonic/gin"

	log "github.com/sirupsen/logrus"
)

// @Summary		Get instrument prices
// @Description	Get current price of each instrument
// @Tags			Pricing-service
// @Accept			*/*
// @Produce		json
// @Produce		application/xml
// @Success		200	{object}	price.pricesResult
// @Router			/v1/prices/latest [get]
func GetCurrentPrices(ctx *gin.Context) {
	log.WithContext(ctx.Request.Context()).Info("Getting current prices")

	var priceList []price

	services.DB.WithContext(queryContext(ctx)).Where("Timestamp = (?)", services.DB.Table("Pricing").Select("max(Timestamp)")).Find(&priceList)

	negotiateResponse(ctx, http.StatusOK, &pricesResult{
		Results: priceList,
	})
	services.SendDataToRabbitQueue(ctx.Request.Context(), prepareCSV(priceList, utils.RandomIntProvider{}))
}

// @Summary		Get instrument price
// @Description	Get last price of instrument
// @Tags			Pricing-service
// @Accept			*/*
// @Produce		json
// @Produce		application/xml
// @Success		200	{object}	price.price
// @Router			/v1/prices/last [get]
func GetLastPrice(ctx *gin.Context) {
	log.WithContext(ctx.Request.Context()).Info("Getting last price")

	var lastPrice price

	services.DB.WithContext(queryContext(ctx)).Last(&lastPrice)

	negotiateResponse(ctx, http.StatusOK, &lastPrice)
	services.SendDataToRabbitQueue(ctx.Request.Context(), prepareCSV([]price{lastPrice}, utils.RandomIntProvider{}))
}

// @Summary		Get prices of a particular instrument
// @Description	Get specific number of records of particular instrument
// @Tags			Pricing-service
// @Accept			*/*
// @Produce		json
// @Produce		application/xml
// @Success		200	{object}	price.pricesResult
// @Router			/v1/prices/instrument/{instrumentId} [get]
// @Param			instrumentId	path	int	true	"Instrument id"
// @Param			records			query	int	false	"Number of records"
func GetPricingDataForInstrument(ctx *gin.Context) {
	instrumentId := ctx.Param("instrumentId")
	records, _ := strconv.Atoi(ctx.DefaultQuery("records", "100"))

	log.WithContext(ctx.Request.Context()).WithFields(log.Fields{
		"instrumentId": instrumentId,
		"records":      records,
	}).Info("Getting pricing data for instrument")

	var priceList []price

	services.DB.WithContext(queryContext(ctx)).Table("Pricing").Where("instrumentId = ?", instrumentId).Order("Timestamp desc").Limit(records).Scan(&priceList)

	negotiateResponse(ctx, http.StatusOK, &pricesResult{
		Results: priceList,
	})
	services.SendDataToRabbitQueue(ctx.Request.Context(), prepareCSV(priceList, utils.RandomIntProvider{}))
}

func prepareCSV(priceList []price, provider utils.IntProvider) string {
	var stringBuilder strings.Builder
	stringBuilder.WriteString("date, open, high, low, close, volume\n")

	for _, item := range priceList {
		stringBuilder.WriteString(item.toCSV(provider.Intn(100) + 100))
	}

	return stringBuilder.String()
}

// queryContext carries the request's trace into a query without the request's
// cancellation: a client that hangs up must not empty the result that is then
// published to RabbitMQ.
func queryContext(ctx *gin.Context) context.Context {
	return context.WithoutCancel(ctx.Request.Context())
}

func negotiateResponse(ctx *gin.Context, status int, data any) {
	ctx.Negotiate(status, gin.Negotiate{
		Offered: []string{gin.MIMEJSON, gin.MIMEXML},
		Data:    data,
	})
}
