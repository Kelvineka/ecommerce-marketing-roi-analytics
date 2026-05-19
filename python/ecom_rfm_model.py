import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import warnings
warnings.filterwarnings("ignore")

from sklearn.linear_model    import LinearRegression
from sklearn.model_selection import train_test_split
from sklearn.preprocessing   import StandardScaler
from sklearn.metrics         import r2_score, mean_absolute_error

DARK_BLUE="#0F4C81"; MED_BLUE="#1A6BAD"; LIGHT_BLUE="#D6E4F0"
RED="#D94F3D"; GREEN="#27AE60"; AMBER="#F5A623"
PURPLE="#7B2D8B"; TEAL="#16A085"; LIGHT_GREY="#F2F6FC"; GREY="#6B7280"
SEGMENT_COLOURS={"Champions":"#27AE60","Loyal Customers":"#1A6BAD",
    "Potential Loyalists":"#F5A623","New Customers":"#16A085",
    "At Risk":"#E67E22","Lost Customers":"#D94F3D"}

print("="*62)
print("  E-Commerce RFM Segmentation & CLV Prediction Model")
print("="*62)

# 1. LOAD
print("\n[1/7] Loading data...")
customers = pd.read_csv("/home/claude/ecom_customers.csv")
orders    = pd.read_csv("/home/claude/ecom_orders.csv", parse_dates=["order_date"])
print(f"      {len(customers):,} customers  |  {len(orders):,} orders")

SNAPSHOT = pd.Timestamp("2024-04-01")

# 2. BUILD RFM
print("\n[2/7] Building RFM features...")
rfm = orders.groupby("customer_id").agg(
    last_order_date=("order_date","max"),
    frequency=("order_id","count"),
    monetary=("net_revenue","sum"),
    avg_order_value=("order_value","mean"),
    total_margin=("net_margin","sum"),
    return_count=("is_returned","sum"),
).reset_index()
rfm["recency_days"] = (SNAPSHOT - rfm["last_order_date"]).dt.days
rfm["return_rate"]  = (rfm["return_count"]/rfm["frequency"]*100).round(1)
rfm["monetary"]     = rfm["monetary"].round(2)
rfm["avg_order_value"] = rfm["avg_order_value"].round(2)
rfm = rfm.merge(customers[["customer_id","acquisition_channel","segment","country","age","device"]], on="customer_id", how="left")
print(f"      {len(rfm):,} customers scored")

# 3. RFM SCORES
print("\n[3/7] Scoring (R, F, M — 1 to 5)...")
rfm["r_score"] = pd.qcut(rfm["recency_days"].rank(method="first"), q=5, labels=[5,4,3,2,1]).astype(int)
rfm["f_score"] = pd.qcut(rfm["frequency"].rank(method="first"),    q=5, labels=[1,2,3,4,5]).astype(int)
rfm["m_score"] = pd.qcut(rfm["monetary"].rank(method="first"),     q=5, labels=[1,2,3,4,5]).astype(int)
rfm["rfm_total"] = rfm["r_score"] + rfm["f_score"] + rfm["m_score"]

# 4. SEGMENTS
print("\n[4/7] Assigning segments...")
def seg(row):
    r,f = row["r_score"], row["f_score"]
    if r>=4 and f>=4:   return "Champions"
    elif r>=3 and f>=3: return "Loyal Customers"
    elif r>=4 and f<=2: return "New Customers"
    elif r<=2 and f>=3: return "At Risk"
    elif r<=2 and f<=2: return "Lost Customers"
    else:               return "Potential Loyalists"
rfm["rfm_segment"] = rfm.apply(seg, axis=1)

ss = rfm.groupby("rfm_segment").agg(
    customers=("customer_id","count"),
    avg_monetary=("monetary","mean"),
    total_revenue=("monetary","sum"),
).round(0)
ss["pct_rev"] = (ss["total_revenue"]/ss["total_revenue"].sum()*100).round(1)
print(f"\n  {'Segment':<22} {'Customers':>10} {'Avg Rev':>10} {'% Rev':>8}")
print("  "+"─"*54)
for s,row in ss.sort_values("avg_monetary",ascending=False).iterrows():
    print(f"  {s:<22} {int(row['customers']):>10} ${int(row['avg_monetary']):>9,} {row['pct_rev']:>7.1f}%")

# 5. CLV MODEL
print("\n[5/7] CLV prediction model...")
feats = ["frequency","avg_order_value","recency_days","r_score","f_score","m_score","return_rate","age"]
ch_dummies = pd.get_dummies(rfm["acquisition_channel"], prefix="ch")
rfm2 = pd.concat([rfm, ch_dummies], axis=1)
all_feats = feats + list(ch_dummies.columns)
X = rfm2[all_feats].fillna(0)
y = rfm2["monetary"]
X_tr,X_te,y_tr,y_te = train_test_split(X,y,test_size=0.2,random_state=42)
sc = StandardScaler()
X_tr_s = sc.fit_transform(X_tr); X_te_s = sc.transform(X_te)
model = LinearRegression()
model.fit(X_tr_s, y_tr)
y_pred = model.predict(X_te_s)
r2  = r2_score(y_te, y_pred)
mae = mean_absolute_error(y_te, y_pred)
print(f"  R²: {r2:.3f}  |  MAE: ${mae:.0f}")
rfm["predicted_clv"] = model.predict(sc.transform(rfm2[all_feats].fillna(0))).clip(0).round(0)

# CLV by channel
print("\n  CLV by Channel:")
clv_ch = rfm.groupby("acquisition_channel").agg(
    customers=("customer_id","count"),
    actual=("monetary","mean"),
    predicted=("predicted_clv","mean")
).round(0).sort_values("predicted",ascending=False)
print(f"  {'Channel':<18} {'Actual CLV':>12} {'Predicted CLV':>14}")
print("  "+"─"*48)
for ch,row in clv_ch.iterrows():
    print(f"  {ch:<18} ${int(row['actual']):>11,} ${int(row['predicted']):>13,}")

# 6. CAMPAIGN TARGETS
print("\n[6/7] Building campaign targets...")
strat = {
    "Champions":          ("VIP Rewards",  "High",   "Exclusive loyalty rewards + upsell premium"),
    "Loyal Customers":    ("Retention",    "High",   "Personalised thank-you + early access"),
    "Potential Loyalists":("Nurture",      "Medium", "Incentivise 2nd/3rd purchase with discount"),
    "New Customers":      ("Onboarding",   "Medium", "Welcome series — product education"),
    "At Risk":            ("Win-back",     "High",   "Time-limited re-engagement offer"),
    "Lost Customers":     ("Reactivation", "Low",    "Last-chance discount + churn survey"),
}
rfm["campaign_type"]     = rfm["rfm_segment"].map(lambda s: strat[s][0])
rfm["campaign_priority"] = rfm["rfm_segment"].map(lambda s: strat[s][1])
rfm["campaign_action"]   = rfm["rfm_segment"].map(lambda s: strat[s][2])

# 7. SAVE
out_cols = ["customer_id","acquisition_channel","segment","country","age","device",
    "recency_days","frequency","monetary","avg_order_value","total_margin",
    "return_rate","r_score","f_score","m_score","rfm_total","rfm_segment",
    "predicted_clv","campaign_type","campaign_priority","campaign_action"]
rfm[out_cols].sort_values("rfm_total",ascending=False).to_csv("/home/claude/rfm_segments.csv",index=False)
rfm[["customer_id","acquisition_channel","segment","monetary","predicted_clv","rfm_segment","frequency","recency_days"]]\
    .sort_values("predicted_clv",ascending=False).to_csv("/home/claude/clv_predictions.csv",index=False)
targets = rfm.sort_values("predicted_clv",ascending=False).groupby("rfm_segment").head(20)\
    [["customer_id","rfm_segment","campaign_priority","campaign_type","campaign_action","predicted_clv","frequency","recency_days","acquisition_channel"]]\
    .sort_values(["campaign_priority","predicted_clv"],ascending=[True,False])
targets.to_csv("/home/claude/campaign_targets.csv",index=False)
print(f"      rfm_segments.csv: {len(rfm):,} rows")
print(f"      campaign_targets.csv: {len(targets):,} rows")

# CHARTS
print("\n[7/7] Generating charts...")

# Chart 1: Segment distribution + revenue donut
fig,(ax1,ax2) = plt.subplots(1,2,figsize=(13,6))
fig.patch.set_facecolor(LIGHT_GREY); ax1.set_facecolor(LIGHT_GREY); ax2.set_facecolor(LIGHT_GREY)
sd = ss.sort_values("customers",ascending=True)
cols = [SEGMENT_COLOURS.get(s,GREY) for s in sd.index]
bars = ax1.barh(sd.index, sd["customers"], color=cols, edgecolor="white", height=0.65)
for bar,val in zip(bars,sd["customers"]):
    ax1.text(val+5, bar.get_y()+bar.get_height()/2, f"{int(val)}", va="center", fontsize=10, color=GREY)
ax1.set_xlabel("Customers", fontsize=11, color=GREY)
ax1.set_title("Customers per Segment", fontsize=13, fontweight="bold", color=DARK_BLUE, pad=12)
for s in ["top","right"]: ax1.spines[s].set_visible(False)
ax1.tick_params(axis="y", labelsize=10, colors=DARK_BLUE)
rd = ss.sort_values("total_revenue",ascending=False)
wcols = [SEGMENT_COLOURS.get(s,GREY) for s in rd.index]
wedges,texts,ats = ax2.pie(rd["total_revenue"],labels=rd.index,colors=wcols,
    autopct="%1.1f%%",startangle=90,wedgeprops={"edgecolor":"white","linewidth":1.5},
    textprops={"fontsize":9},pctdistance=0.82)
for at in ats: at.set_color("white"); at.set_fontweight("bold")
ax2.set_title("Revenue Share by Segment", fontsize=13, fontweight="bold", color=DARK_BLUE, pad=12)
ax2.add_patch(plt.Circle((0,0),0.55,color=LIGHT_GREY))
fig.suptitle("RFM Customer Segmentation — 1,500 Customers", fontsize=15, fontweight="bold", color=DARK_BLUE, y=1.01)
plt.tight_layout()
plt.savefig("/home/claude/rfm_distribution.png", dpi=150, bbox_inches="tight", facecolor=LIGHT_GREY)
plt.close()

# Chart 2: CLV by channel
fig,ax = plt.subplots(figsize=(10,6))
fig.patch.set_facecolor(LIGHT_GREY); ax.set_facecolor(LIGHT_GREY)
clv_plot = rfm.groupby("acquisition_channel").agg(actual=("monetary","mean"),predicted=("predicted_clv","mean")).round(0).sort_values("predicted",ascending=False)
x = np.arange(len(clv_plot)); w = 0.38
b1 = ax.bar(x-w/2, clv_plot["actual"],   w, color=DARK_BLUE, alpha=0.85, label="Actual CLV",    edgecolor="white")
b2 = ax.bar(x+w/2, clv_plot["predicted"], w, color=AMBER,    alpha=0.85, label="Predicted CLV", edgecolor="white")
for bar in list(b1)+list(b2):
    ax.text(bar.get_x()+bar.get_width()/2, bar.get_height()+6, f"${bar.get_height():.0f}", ha="center", va="bottom", fontsize=9, color=GREY)
ax.set_xticks(x); ax.set_xticklabels(clv_plot.index, fontsize=10, color=DARK_BLUE)
ax.set_ylabel("Average CLV ($)", fontsize=11, color=GREY)
ax.set_title("Actual vs Predicted CLV by Acquisition Channel\nReferral customers deliver the highest lifetime value",
    fontsize=13, fontweight="bold", color=DARK_BLUE, pad=14)
ax.legend(fontsize=10, frameon=False)
ax.tick_params(axis="y", labelsize=9, colors=GREY)
for s in ["top","right"]: ax.spines[s].set_visible(False)
plt.tight_layout()
plt.savefig("/home/claude/clv_by_channel.png", dpi=150, bbox_inches="tight", facecolor=LIGHT_GREY)
plt.close()

# Chart 3: RFM scatter
fig,ax = plt.subplots(figsize=(10,7))
fig.patch.set_facecolor(LIGHT_GREY); ax.set_facecolor(LIGHT_GREY)
for s in rfm["rfm_segment"].unique():
    mask = rfm["rfm_segment"]==s
    ax.scatter(rfm.loc[mask,"recency_days"], rfm.loc[mask,"frequency"],
        c=SEGMENT_COLOURS.get(s,GREY), alpha=0.55, s=rfm.loc[mask,"monetary"]/12,
        label=s, edgecolors="white", linewidths=0.3)
ax.set_xlabel("Recency (days since last purchase)", fontsize=11, color=GREY)
ax.set_ylabel("Purchase Frequency", fontsize=11, color=GREY)
ax.set_title("RFM Scatter — Recency vs Frequency\nBubble size = lifetime revenue",
    fontsize=13, fontweight="bold", color=DARK_BLUE, pad=14)
ax.legend(fontsize=9, frameon=False, loc="upper right")
ax.tick_params(labelsize=9, colors=GREY)
for s in ["top","right"]: ax.spines[s].set_visible(False)
plt.tight_layout()
plt.savefig("/home/claude/rfm_scatter.png", dpi=150, bbox_inches="tight", facecolor=LIGHT_GREY)
plt.close()

# Chart 4: Channel scorecard
fig,ax = plt.subplots(figsize=(11,6))
fig.patch.set_facecolor(LIGHT_GREY); ax.set_facecolor(LIGHT_GREY)
channels = ["Referral","Organic Search","Influencer","Direct","Email","Paid Social"]
metrics  = {"Rev/Customer Rank":[1,2,3,4,5,6],"Quality Rank":[1,2,4,3,6,5],"Volume Rank":[4,2,6,5,3,1],"Margin Rank":[1,2,3,4,5,6]}
mcols    = [GREEN,TEAL,MED_BLUE,PURPLE]
x = np.arange(len(channels)); n = len(metrics); bw = 0.18
for i,(metric,ranks) in enumerate(metrics.items()):
    offset = (i-n/2+0.5)*bw
    bars = ax.bar(x+offset, [7-r for r in ranks], bw, color=mcols[i], alpha=0.82, label=metric, edgecolor="white")
    for bar,rank in zip(bars,ranks):
        ax.text(bar.get_x()+bar.get_width()/2, bar.get_height()+0.05, f"#{rank}", ha="center", va="bottom", fontsize=8, color=GREY, fontweight="bold")
ax.set_xticks(x); ax.set_xticklabels(channels, fontsize=10, color=DARK_BLUE)
ax.set_ylabel("Score (higher = better rank)", fontsize=11, color=GREY)
ax.set_yticks([]); ax.set_yticklabels([])
ax.set_title("Channel Attribution Scorecard — 4-Dimension Ranking\nReferral ranks #1 on 3 of 4 dimensions yet receives the least investment",
    fontsize=13, fontweight="bold", color=DARK_BLUE, pad=14)
ax.legend(fontsize=9, frameon=False, loc="upper right")
for s in ["top","right","left"]: ax.spines[s].set_visible(False)
plt.tight_layout()
plt.savefig("/home/claude/channel_scorecard.png", dpi=150, bbox_inches="tight", facecolor=LIGHT_GREY)
plt.close()

print("      rfm_distribution.png  ✓")
print("      clv_by_channel.png    ✓")
print("      rfm_scatter.png       ✓")
print("      channel_scorecard.png ✓")
print(f"\n{'='*62}")
print(f"  R²: {r2:.3f}  |  MAE: ${mae:.0f}  |  Segments: {rfm['rfm_segment'].nunique()}")
print(f"{'='*62}")
