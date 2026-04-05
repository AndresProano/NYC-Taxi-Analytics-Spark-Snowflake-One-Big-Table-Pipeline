# NYC Taxi Analytics — Spark + Snowflake One Big Table Pipeline

**Universidad San Francisco de Quito — Data Mining — Proyecto 03**

## Integrantes

| Nombre | ID |
|--------|-----|
| Andres Proano | 00326003 |
| Julian Leon | |
| Benjamin Vaca | |
| Mauricio Mantilla | |
| Pablo Alvarado | 00344965 |

---

## 1. Resumen

Pipeline de datos end-to-end que ingesta los registros de viajes de taxis de NYC (Yellow y Green, 2015–2025) desde archivos Parquet publicos, los procesa con Apache Spark en Jupyter y los almacena en Snowflake. Se construye una **One Big Table (OBT)** desnormalizada en el esquema `analytics` para responder 20 preguntas de negocio sin necesidad de JOINs.

---

## 2. Arquitectura

```
┌─────────────────────┐
│   NYC TLC Parquet   │
│   (2015 – 2025)     │
│  Yellow  &  Green   │
└────────┬────────────┘
         │  HTTPS download
         ▼
┌─────────────────────┐
│   spark-notebook    │
│  (Jupyter + Spark)  │
│  Docker Container   │
│  Ports: 8888, 4040  │
└────────┬────────────┘
         │  Snowflake JDBC
         ▼
┌─────────────────────────────────────────────┐
│                 SNOWFLAKE                   │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │   RAW    │  │ CURATED  │  │ ANALYTICS │ │
│  │          │  │          │  │           │ │
│  │ YELLOW_  │  │ DIM_TAXI │  │ OBT_TRIPS │ │
│  │ TRIPS    │→ │ _ZONES   │→ │           │ │
│  │          │  │ DIM_     │  │ OBT_TRIPS │ │
│  │ GREEN_   │  │ VENDOR   │  │ _MONTHLY  │ │
│  │ TRIPS    │  │ DIM_RATE │  │           │ │
│  │          │  │ _CODE    │  │           │ │
│  │ LOAD_    │  │ DIM_PAY  │  │           │ │
│  │ AUDIT    │  │ FCT_TRIPS│  │           │ │
│  │          │  │ _ENRICHED│  │           │ │
│  └──────────┘  └──────────┘  └───────────┘ │
└─────────────────────────────────────────────┘
```

**Flujo:** Parquet (S3) → Spark (backfill mensual) → `RAW` → enriquecimiento/unificacion → `CURATED` → construccion OBT → `ANALYTICS.OBT_TRIPS`

---

## 3. Infraestructura — Docker Compose

Un unico servicio `spark-notebook` basado en `jupyter/pyspark-notebook:latest`:

| Propiedad | Valor |
|-----------|-------|
| Imagen | `jupyter/pyspark-notebook:latest` |
| Puertos | `8888` (Jupyter), `4040` (Spark UI) |
| Volumenes | `./notebooks` → `/home/jovyan/work`, `./jars` → `/home/jovyan/jars` |
| Variables | Cargadas desde `.env` via `env_file` |

### Levantar el ambiente

```bash
# 1. Copiar y llenar credenciales
cp .env.example .env
# Editar .env con las credenciales de Snowflake

# 2. Levantar el contenedor
docker compose up -d

# 3. Ver el token de Jupyter
docker compose logs spark-notebook

# 4. Abrir Jupyter en el navegador
# http://localhost:8888/?token=<TOKEN>

# 5. Abrir Spark UI (cuando un notebook esta corriendo)
# http://localhost:4040
```

---

## 4. Variables de ambiente

Definidas en `.env` (credenciales reales) y `.env.example` (plantilla sin secretos).

| Variable | Proposito |
|----------|-----------|
| `SF_HOST` | URL de la cuenta Snowflake |
| `SF_PORT` | Puerto de conexion |
| `SF_DATABASE` | Base de datos destino |
| `SF_USER` | Usuario de Snowflake |
| `SF_PASSWORD` | Contrasena de Snowflake |
| `SF_RAW_SCHEMA` | Esquema para aterrizaje raw (default: `RAW`) |
| `SF_ANALYTICS_SCHEMA` | Esquema para la OBT (default: `ANALYTICS`) |
| `SF_WAREHOUSE` | Warehouse de computo |
| `SF_ROLE` | Rol de acceso |
| `SERVICES` | Tipos de taxi a procesar (`yellow,green`) |
| `START_YEAR` | Ano inicial de ingesta (`2015`) |
| `END_YEAR` | Ano final de ingesta (`2025`) |
| `MONTHS` | Meses a procesar (`1,2,...,12`) |
| `RUN_ID` | Identificador unico de ejecucion |
| `VALIDATE_OUTLIERS` | Flag para activar validacion de outliers |
| `YELLOW_BASE_URL` | URL base de los Parquet de Yellow Taxi |
| `GREEN_BASE_URL` | URL base de los Parquet de Green Taxi |
| `TAXI_ZONE_PATH` | Ruta al CSV de Taxi Zone Lookup |

---

## 5. Notebooks — Orden de ejecucion

Los notebooks deben ejecutarse en orden secuencial (01 → 02 → 03 → 04 → 05):

### 01_ingesta_parquet_raw.ipynb
- Descarga archivos Parquet de Yellow y Green taxis (2015–2025) mes a mes desde el CDN de NYC TLC.
- Estandariza esquemas y tipos de datos.
- Genera clave natural (`trip_nk`) via SHA-256 sobre campos clave.
- Escribe en `RAW.YELLOW_TRIPS` y `RAW.GREEN_TRIPS`.
- Registra auditoria por lote en `RAW.LOAD_AUDIT` (run_id, servicio, ano, mes, status, timestamp).
- Idempotencia: si se reingesta un mes, los registros previos se reemplazan.

### 02_enriquecimiento_y_unificacion.ipynb
- Lee tablas RAW de Snowflake.
- Estandariza timestamps (`pickup_datetime_utc`, `dropoff_datetime_utc`).
- Integra Taxi Zones (borough, zone, service_zone) para pickup y dropoff.
- Normaliza catalogos operativos con tablas de dimension:
  - `DIM_VENDOR`: Creative Mobile Technologies, VeriFone Inc., Myle Technologies Inc.
  - `DIM_RATE_CODE`: Standard, JFK, Newark, Nassau/Westchester, Negotiated, Group ride.
  - `DIM_PAYMENT_TYPE`: Credit card, Cash, No charge, Dispute, Unknown, Voided.
  - `DIM_TRIP_TYPE`: Street-hail, Dispatch (solo Green).
  - `DIM_STORE_AND_FWD`: Stored and forwarded / Not a stored trip.
- Unifica Yellow y Green en `CURATED.FCT_TRIPS_ENRICHED` como capa intermedia de staging.

### 03_construccion_obt.ipynb
- Lee `CURATED.FCT_TRIPS_ENRICHED`.
- Aplica filtros de calidad minima (trip_nk no nulo, duracion > 0, timestamps no nulos).
- Construye features derivadas (ver seccion 6).
- Publica `ANALYTICS.OBT_TRIPS` (tabla principal) y `ANALYTICS.OBT_TRIPS_MONTHLY` (agregado mensual).
- Nota: el entregable obligatorio del PDF es `analytics.obt_trips`; `OBT_TRIPS_MONTHLY` es un extra opcional.

### 04_validaciones_y_exploracion.ipynb
- Valida nulos en columnas esenciales.
- Valida rangos logicos (distancias, duraciones, montos negativos, velocidades imposibles).
- Verifica coherencia temporal (dropoff posterior a pickup).
- Detecta duplicados por `trip_nk` (verificacion de idempotencia).
- Compara conteos RAW vs OBT por servicio/ano/mes con delta y porcentaje retenido.
- Construye la matriz de cobertura desde `RAW.LOAD_AUDIT`.

### 05_data_analysis.ipynb
- Responde las 20 preguntas de negocio consultando `ANALYTICS.OBT_TRIPS` con Spark.

---

## 6. Diseno de esquemas en Snowflake

### 6.1 Esquema RAW (aterrizaje)

**Tablas:** `YELLOW_TRIPS`, `GREEN_TRIPS`

Contienen todas las columnas originales del Parquet mas metadatos de ingesta:

| Columna | Descripcion |
|---------|-------------|
| `trip_nk` | Clave natural SHA-256 (VendorID + timestamps + total_amount + service_type) |
| `run_id` | Identificador de la ejecucion |
| `service_type` | `yellow` o `green` |
| `source_year` | Ano del archivo fuente |
| `source_month` | Mes del archivo fuente |
| `ingested_at_utc` | Timestamp de carga |
| `source_path` | URL del Parquet descargado |

**Tabla de auditoria:** `LOAD_AUDIT`

| Columna | Descripcion |
|---------|-------------|
| `run_id` | Identificador de ejecucion |
| `service` | Tipo de taxi |
| `year`, `month` | Periodo procesado |
| `status` | `SUCCESS`, `Missing`, o `ERROR` |
| `event_timestamp` | Momento de la carga |
| `notes` | Detalle de errores (si aplica) |

### 6.2 Capa intermedia CURATED (staging interno)

**Tabla principal:** `FCT_TRIPS_ENRICHED` — Yellow y Green unificados con zonas y catalogos resueltos. Esta capa no reemplaza el requerimiento formal del PDF; funciona como staging previo a `ANALYTICS.OBT_TRIPS`.

**Dimensiones:** `DIM_TAXI_ZONES`, `DIM_VENDOR`, `DIM_RATE_CODE`, `DIM_PAYMENT_TYPE`, `DIM_TRIP_TYPE`, `DIM_STORE_AND_FWD`.

### 6.3 Esquema ANALYTICS (One Big Table)

**Tabla:** `ANALYTICS.OBT_TRIPS`

**Grano:** 1 fila = 1 viaje.

| Grupo | Columnas |
|-------|----------|
| Claves | `obt_trip_sk`, `trip_nk` |
| Servicio | `taxi_type`, `service_type` |
| Tiempo | `trip_date`, `trip_year`, `trip_month`, `trip_day`, `trip_day_of_week`, `pickup_datetime_utc`, `dropoff_datetime_utc`, `pickup_hour`, `pickup_time_band`, `is_weekend` |
| Ubicacion PU | `PULocationID`, `pu_borough`, `pu_zone`, `pu_service_zone` |
| Ubicacion DO | `DOLocationID`, `do_borough`, `do_zone`, `do_service_zone` |
| Ruta | `route_key` (formato `PU_zone -> DO_zone`) |
| Catalogos | `vendor_id`, `vendor_desc`, `rate_code_id`, `rate_code_desc`, `payment_type_code`, `payment_type_desc`, `trip_type_code`, `trip_type_desc`, `store_and_fwd_flag_norm`, `store_and_fwd_desc` |
| Viaje | `passenger_count`, `trip_distance_miles`, `trip_distance_km`, `distance_bucket` |
| Tarifas | `fare_amount`, `extra`, `mta_tax`, `tip_amount`, `tolls_amount`, `improvement_surcharge`, `congestion_surcharge`, `airport_fee`, `total_amount` |
| Derivadas | `trip_duration_minutes`, `avg_speed_mph`, `tip_pct`, `fare_per_mile` |
| Lineage | `source_year`, `source_month`, `run_id`, `ingested_at_utc` |

#### Columnas derivadas — reglas de calculo

| Columna | Formula | Manejo de nulos/ceros |
|---------|---------|----------------------|
| `trip_duration_minutes` | `(dropoff_utc - pickup_utc) / 60` | Calculado en notebook 02; filtrado si es nulo o <= 0 en notebook 03 |
| `avg_speed_mph` | `trip_distance_miles / (trip_duration_minutes / 60)` | `NULL` si duracion es 0 |
| `tip_pct` | `(tip_amount / fare_amount) * 100` | `NULL` si fare_amount <= 0 |
| `fare_per_mile` | `fare_amount / trip_distance_miles` | `NULL` si distancia <= 0 |
| `distance_bucket` | `<1 mi`, `1-3 mi`, `3-7 mi`, `7-15 mi`, `15+ mi` | Basado en `trip_distance_miles` |
| `pickup_time_band` | `morning` (6-11), `afternoon` (12-17), `evening` (18-23), `night` (0-5) | Basado en `pickup_hour` |

**Tabla agregada:** `ANALYTICS.OBT_TRIPS_MONTHLY` — Resumen mensual por taxi_type, borough PU/DO y payment_type con metricas: trips_count, total_revenue, avg_ticket, avg_distance, avg_duration, avg_tip_pct.

---

## 7. Calidad, auditoria y validaciones

### Reglas de calidad aplicadas (notebook 03)
- `trip_nk` no nulo.
- `pickup_datetime_utc` y `dropoff_datetime_utc` no nulos.
- `total_amount` no nulo.
- `trip_duration_minutes` no nulo y > 0.

### Validaciones ejecutadas (notebook 04)
- **Nulos:** verificacion en 9 columnas esenciales.
- **Rangos:** distancia negativa, duracion negativa, montos negativos, velocidad > 100 mph, duracion > 24 horas.
- **Coherencia temporal:** dropoff anterior a pickup.
- **Duplicados:** deteccion por `trip_nk`.
- **Conteos RAW vs OBT:** delta y porcentaje retenido por servicio/ano/mes.
- **Cobertura:** matriz desde `LOAD_AUDIT` por servicio y periodo.

### Auditoria
- Cada ejecucion de ingesta registra un `run_id` unico (timestamp).
- `LOAD_AUDIT` almacena el status por servicio/ano/mes: `SUCCESS`, `Missing` (Parquet no disponible), `ERROR`.
- Los conteos por lote se verifican en notebook 04.

---

## 8. Matriz de cobertura 2015–2025

La matriz de cobertura debe generarse automaticamente en el notebook `04_validaciones_y_exploracion.ipynb` a partir de `RAW.LOAD_AUDIT`.

> Estado actual del repo: esta matriz todavia no esta materializada como evidencia versionada. No debe marcarse cobertura completa hasta ejecutar la ingesta y guardar la evidencia resultante.

---

## 9. Estructura del repositorio

```
.
├── docker-compose.yml          # Servicio spark-notebook
├── .env.example                # Plantilla de variables de ambiente
├── .env                        # Variables con credenciales (no versionado)
├── README.md                   # Este archivo
├── DM-PSet-3.pdf               # Enunciado del proyecto
├── notebooks/
│   ├── 01_ingesta_parquet_raw.ipynb
│   ├── 02_enriquecimiento_y_unificacion.ipynb
│   ├── 03_construccion_obt.ipynb
│   ├── 04_validaciones_y_exploracion.ipynb
│   └── 05_data_analysis.ipynb
├── jars/                       # JARs para conectores (Snowflake JDBC)
└── evidence/                   # Capturas de ejecucion
```

---

## 10. Checklist de aceptacion

- [ ] Docker Compose levanta Spark y Jupyter Notebook.
- [ ] Todas las credenciales/parametros provienen de variables de ambiente (`.env`).
- [ ] Cobertura 2015–2025 (Yellow/Green) cargada en `raw` con matriz y conteos por lote.
- [ ] `analytics.obt_trips` creada con columnas minimas, derivadas y metadatos.
- [ ] Idempotencia verificada reingestando al menos un mes.
- [ ] Validaciones basicas documentadas (nulos, rangos, coherencia).
- [ ] 20 preguntas respondidas usando la OBT.
- [ ] README claro: pasos, variables, esquema, decisiones, troubleshooting.

---

## 11. Troubleshooting

| Problema | Solucion |
|----------|----------|
| Jupyter no arranca | Verificar que Docker este corriendo: `docker compose ps` |
| Error de conexion a Snowflake | Verificar variables en `.env` (SF_HOST, SF_USER, SF_PASSWORD) |
| Parquet 404/403 | El mes no esta disponible en TLC; queda registrado como `Missing` en LOAD_AUDIT |
| Spark out of memory | Reducir el rango de anos/meses en las variables de ambiente |
| Puerto 8888 ocupado | Cambiar el mapeo en `docker-compose.yml` (e.g., `8889:8888`) |
| JARs no encontrados | Colocar los JARs de Snowflake JDBC y Spark connector en `./jars/`; el contenedor expone `/home/jovyan/jars` via `SPARK_EXTRA_CLASSPATH` |
