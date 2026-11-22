"""
Generate a SMALL SYNTHETIC dataset with exactly the same files and columns as the
real Olist Kaggle dataset. It exists only so the pipeline can be tested end to end
before the real data is downloaded. Never present numbers from this sample as findings.

Usage:  python tests/make_sample_data.py            -> writes CSVs into data/raw/
        python tests/make_sample_data.py --out DIR
"""
import argparse
import csv
import os
import random
from datetime import datetime, timedelta

random.seed(42)

STATES = ["SP", "RJ", "MG", "RS", "PR", "SC", "BA", "PE", "CE", "GO", "DF", "AM", "PA"]
CITIES = {"SP": "sao paulo", "RJ": "rio de janeiro", "MG": "belo horizonte", "RS": "porto alegre",
          "PR": "curitiba", "SC": "florianopolis", "BA": "salvador", "PE": "recife", "CE": "fortaleza",
          "GO": "goiania", "DF": "brasilia", "AM": "manaus", "PA": "belem"}
FAR_STATES = {"AM", "PA", "CE", "PE", "BA"}  # longer, riskier deliveries
CATEGORIES = [("cama_mesa_banho", "bed_bath_table"), ("beleza_saude", "health_beauty"),
              ("esporte_lazer", "sports_leisure"), ("moveis_decoracao", "furniture_decor"),
              ("informatica_acessorios", "computers_accessories"), ("utilidades_domesticas", "housewares"),
              ("relogios_presentes", "watches_gifts"), ("telefonia", "telephony"),
              ("brinquedos", "toys"), ("eletronicos", "electronics")]
PAYMENT_TYPES = ["credit_card"] * 7 + ["boleto"] * 2 + ["voucher", "debit_card"]

# Portuguese review templates by (hidden) true complaint category
TEMPLATES = {
    "late_delivery": ["Produto chegou com muito atraso, mais de duas semanas depois do prazo.",
                      "Entrega demorou demais, o prazo não foi cumprido.",
                      "Chegou atrasado, mas o produto é bom."],
    "not_delivered": ["Até agora não recebi o produto. Péssimo.",
                      "Comprei e nunca chegou, ninguém responde.",
                      "O pedido consta como entregue mas não recebi nada."],
    "damaged_item": ["O produto veio quebrado e a caixa toda amassada.",
                     "Chegou danificado, a tela estava rachada.",
                     "Veio com defeito, não funciona."],
    "wrong_item": ["Recebi um produto diferente do que comprei.",
                   "Veio a cor errada e o tamanho errado.",
                   "Mandaram outro modelo, não é o que pedi."],
    "missing_parts": ["Comprei dois itens e só recebi um.",
                      "Faltou uma peça no pacote, veio incompleto."],
    "poor_quality": ["Qualidade muito ruim, material fraco.",
                     "O tecido é de péssima qualidade, não recomendo.",
                     "Produto frágil, quebrou na primeira semana de uso."],
    "not_as_described": ["O produto não corresponde à descrição do anúncio.",
                         "A foto é bem diferente do produto real."],
    "seller_communication": ["Tentei falar com o vendedor várias vezes e não tive resposta.",
                             "Atendimento do lojista horrível, não respondem mensagens."],
    "refund_return_issue": ["Pedi a devolução e até hoje não recebi o reembolso.",
                            "Cancelei a compra e o estorno não foi feito."],
    "price_value": ["Achei caro pelo que é.", "O frete foi mais caro que o produto."],
    "positive_feedback": ["Produto excelente, chegou antes do prazo. Recomendo!",
                          "Muito bom, ótima qualidade e entrega rápida.",
                          "Adorei, tudo certo com a compra.", "Perfeito, vendedor nota 10.",
                          "Bom produto, recomendo."],
}
NEVER_AGAIN = [" Nunca mais compro nessa loja.", " Não compro mais aqui.", ""]


def ts(d):
    return d.strftime("%Y-%m-%d %H:%M:%S") if d else ""


def hexid(n=32):
    return "".join(random.choice("0123456789abcdef") for _ in range(n))


def write(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main(out, n_orders=4000):
    os.makedirs(out, exist_ok=True)
    # sellers: a few "problem sellers" with bad packaging / slow shipping
    sellers = []
    for i in range(60):
        st = random.choice(STATES[:8])
        sellers.append({"id": hexid(), "zip": f"{random.randint(1000, 99999):05d}", "city": CITIES[st],
                        "state": st, "risk": random.choice([0.05] * 8 + [0.25, 0.4])})
    products = []
    for i in range(400):
        cat = random.choice(CATEGORIES)
        products.append({"id": hexid(), "cat": cat[0], "price": round(random.uniform(15, 600), 2),
                         "seller": random.choice(sellers)})
    customers = []
    for i in range(int(n_orders * 0.97)):
        st = random.choice(STATES)
        customers.append({"id": None, "uid": hexid(), "zip": f"{random.randint(1000, 99999):05d}",
                          "city": CITIES[st], "state": st})

    rows_c, rows_o, rows_i, rows_p, rows_r, truth_rows = [], [], [], [], [], []
    start = datetime(2017, 1, 5)
    for n in range(n_orders):
        cust = random.choice(customers)
        cid = hexid()  # Olist: a new customer_id per order, customer_unique_id = the real person
        rows_c.append([cid, cust["uid"], cust["zip"], cust["city"], cust["state"]])
        oid = hexid()
        purchase = start + timedelta(days=random.randint(0, 600), minutes=random.randint(0, 1440))
        status = "delivered" if random.random() > 0.03 else random.choice(["canceled", "shipped", "unavailable"])
        approved = purchase + timedelta(hours=random.randint(1, 30))
        est = purchase + timedelta(days=random.randint(15, 35))
        n_items = 1 if random.random() > 0.1 else 2
        items = [random.choice(products) for _ in range(n_items)]
        seller_risk = max(p["seller"]["risk"] for p in items)
        far = cust["state"] in FAR_STATES
        base_days = random.randint(4, 18) + (8 if far else 0) + (12 if random.random() < seller_risk else 0)
        carrier = approved + timedelta(days=random.randint(1, 5))
        delivered = purchase + timedelta(days=base_days, hours=random.randint(0, 20)) if status == "delivered" else None
        rows_o.append([oid, cid, status, ts(purchase), ts(approved), ts(carrier), ts(delivered), ts(est)])
        total = 0
        for k, p in enumerate(items, 1):
            freight = round(random.uniform(7, 60) + (15 if far else 0), 2)
            total += p["price"] + freight
            rows_i.append([oid, k, p["id"], p["seller"]["id"], ts(approved + timedelta(days=3)), f"{p['price']:.2f}",
                           f"{freight:.2f}"])
        rows_p.append([oid, 1, random.choice(PAYMENT_TYPES), random.randint(1, 8), f"{total:.2f}"])

        # review: score depends on lateness + seller risk; ~42% leave a comment (like real Olist)
        late = delivered is not None and delivered > est
        if status != "delivered":
            truth = random.choice(["not_delivered", "refund_return_issue"])
        elif late:
            truth = random.choice(["late_delivery"] * 4 + ["seller_communication"])
        elif random.random() < seller_risk:
            truth = random.choice(["damaged_item", "wrong_item", "missing_parts", "poor_quality"])
        elif random.random() < 0.12:
            truth = random.choice(["poor_quality", "not_as_described", "price_value"])
        else:
            truth = "positive_feedback"
        score = random.choice([4, 5, 5, 5]) if truth == "positive_feedback" else random.choice([1, 1, 2, 3])
        if truth in ("late_delivery", "price_value") and random.random() < 0.3:
            score = 3
        comment = ""
        if random.random() < 0.42 or (truth != "positive_feedback" and random.random() < 0.7):
            comment = random.choice(TEMPLATES[truth])
            if score <= 2:
                comment += random.choice(NEVER_AGAIN)
        created = (delivered or est) + timedelta(days=1)
        rid = hexid()
        rows_r.append([rid, oid, score, "", comment, ts(created), ts(created + timedelta(days=2))])
        if comment:
            truth_rows.append([rid, truth])

    write(f"{out}/olist_customers_dataset.csv",
          ["customer_id", "customer_unique_id", "customer_zip_code_prefix", "customer_city", "customer_state"], rows_c)
    write(f"{out}/olist_orders_dataset.csv",
          ["order_id", "customer_id", "order_status", "order_purchase_timestamp", "order_approved_at",
           "order_delivered_carrier_date", "order_delivered_customer_date", "order_estimated_delivery_date"], rows_o)
    write(f"{out}/olist_order_items_dataset.csv",
          ["order_id", "order_item_id", "product_id", "seller_id", "shipping_limit_date", "price", "freight_value"],
          rows_i)
    write(f"{out}/olist_order_payments_dataset.csv",
          ["order_id", "payment_sequential", "payment_type", "payment_installments", "payment_value"], rows_p)
    write(f"{out}/olist_order_reviews_dataset.csv",
          ["review_id", "order_id", "review_score", "review_comment_title", "review_comment_message",
           "review_creation_date", "review_answer_timestamp"], rows_r)
    write(f"{out}/olist_products_dataset.csv",
          ["product_id", "product_category_name", "product_name_lenght", "product_description_lenght",
           "product_photos_qty", "product_weight_g", "product_length_cm", "product_height_cm", "product_width_cm"],
          [[p["id"], p["cat"], random.randint(20, 60), random.randint(100, 2000), random.randint(1, 6),
            random.randint(100, 9000), random.randint(10, 80), random.randint(5, 60), random.randint(10, 60)]
           for p in products])
    write(f"{out}/olist_sellers_dataset.csv", ["seller_id", "seller_zip_code_prefix", "seller_city", "seller_state"],
          [[s["id"], s["zip"], s["city"], s["state"]] for s in sellers])
    write(f"{out}/product_category_name_translation.csv",
          ["product_category_name", "product_category_name_english"], CATEGORIES)
    write(f"{out}/olist_geolocation_dataset.csv",
          ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng", "geolocation_city",
           "geolocation_state"], [])
    # hidden "true" category per review, used only to simulate manual labels in tests
    write(f"{out}/../_sample_truth.csv", ["review_id", "true_category"], truth_rows)
    print(f"Synthetic sample written to {out}: {n_orders} orders, {len(rows_i)} items, "
          f"{sum(1 for r in rows_r if r[4])} reviews with text")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/raw")
    ap.add_argument("--orders", type=int, default=4000)
    a = ap.parse_args()
    main(a.out, a.orders)
