package app.yuyue.me

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.t
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams

/**
 * 请开发者喝咖啡, as on Apple: three one-off tips that unlock nothing, through Google Play.
 * Consumed as soon as they're paid, so the same one can be given again; nothing is remembered
 * but a thank-you for this visit. The product ids are the App Store's.
 */
class TipJar(context: Context) {
    var products by mutableStateOf<List<ProductDetails>>(emptyList())
        private set
    var buying by mutableStateOf<String?>(null)
        private set
    var thanked by mutableStateOf(false)
        private set
    var problem by mutableStateOf<String?>(null)

    private val client = BillingClient.newBuilder(context.applicationContext)
        .setListener { result, purchases -> bought(result, purchases) }
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()

    fun load() {
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode != BillingClient.BillingResponseCode.OK) return
                val params = QueryProductDetailsParams.newBuilder().setProductList(IDS.map {
                    QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(BillingClient.ProductType.INAPP).build()
                }).build()
                client.queryProductDetailsAsync(params) { _, found ->
                    products = found.productDetailsList.sortedBy { it.oneTimePurchaseOfferDetails?.priceAmountMicros ?: 0 }
                }
            }

            override fun onBillingServiceDisconnected() {}
        })
    }

    fun buy(activity: Activity, product: ProductDetails) {
        buying = product.productId
        problem = null
        val params = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(
            BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product).build(),
        )).build()
        val result = client.launchBillingFlow(activity, params)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            buying = null
            problem = t("没付成（%@）", result.debugMessage.ifEmpty { "${result.responseCode}" })
        }
    }

    private fun bought(result: BillingResult, purchases: List<Purchase>?) {
        buying = null
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> for (p in purchases.orEmpty()) {
                when (p.purchaseState) {
                    Purchase.PurchaseState.PURCHASED -> client.consumeAsync(ConsumeParams.newBuilder().setPurchaseToken(p.purchaseToken).build()) { _, _ -> thanked = true }
                    Purchase.PurchaseState.PENDING -> problem = t("等确认后就完成了")
                    else -> {}
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> {}
            else -> problem = t("没付成（%@）", result.debugMessage.ifEmpty { "${result.responseCode}" })
        }
    }

    fun end() = client.endConnection()

    companion object {
        val IDS = listOf("app.yuyue.tip.small", "app.yuyue.tip.medium", "app.yuyue.tip.large")
        /** Shown until the store answers, and when it can't (no products set up yet). */
        val FALLBACK = listOf("¥6", "¥18", "¥45")
    }
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** `.v-me-cof`: the cup, what a tip does (nothing), three amounts, paid once. */
@Composable
fun TipCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val jar = remember { TipJar(context) }
    DisposableEffect(Unit) {
        jar.load()
        onDispose { jar.end() }
    }
    Column(modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).padding(start = YY.s(13), end = YY.s(13), top = YY.s(13), bottom = YY.s(11))) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
            Box(Modifier.size(YY.s(30)).background(YY.c.inset, RoundedCornerShape(YY.s(8))), contentAlignment = Alignment.Center) {
                Icon(Icons.cup, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(15)))
            }
            Column(verticalArrangement = Arrangement.spacedBy(YY.s(1))) {
                Text(if (jar.thanked) t("谢谢你的咖啡") else t("请开发者喝咖啡"), style = YY.font(12f, FontWeight.SemiBold), color = YY.c.t1)
                Text(if (jar.thanked) t("收到了。语阅会一直免费下去。") else t("不解锁任何功能，给不给用起来都一样。"), style = YY.font(10f), color = YY.c.t3)
            }
        }
        Row(Modifier.padding(top = YY.s(12)), horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
            if (jar.products.isEmpty()) {
                for (price in TipJar.FALLBACK) Tile(price, false, false) {}
            } else {
                for (p in jar.products) Tile(p.oneTimePurchaseOfferDetails?.formattedPrice ?: "", jar.buying == p.productId, jar.buying == null) {
                    context.activity()?.let { jar.buy(it, p) }
                }
            }
        }
        Text(
            jar.problem ?: if (jar.products.isEmpty()) t("在 Google Play 上架之后就能付了。") else t("一次性付款，不会自动续费。"),
            style = YY.font(10f), color = if (jar.problem == null) YY.c.t3 else YY.c.danger, modifier = Modifier.padding(top = YY.s(9)),
        )
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.Tile(price: String, busy: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.weight(1f).height(YY.s(42)).background(YY.c.inset, RoundedCornerShape(YY.s(12))).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(YY.s(14)), strokeWidth = 2.dp, color = YY.tint.accent)
        else Text(price, style = YY.font(14f, FontWeight.Bold), color = if (enabled) YY.c.t1 else YY.c.t3)
    }
}
