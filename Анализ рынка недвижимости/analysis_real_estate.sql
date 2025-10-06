/* ============================================================
   Проект: Анализ данных для агентства недвижимости
   Описание: Серия Ad-hoc задач по рынку СПб и Ленобласти
   ============================================================ */

/* ===================== Оглавление ===========================
   Задача 1 — Время активности объявлений
   Задача 2 — Сезонность объявлений
   Задача 3 — Анализ рынка недвижимости Ленобласти
   ============================================================ */

-- Базовая очистка данных
-- Определим аномальные значения (выбросы) по значению перцентилей:
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Найдем id объявлений, которые не содержат выбросы:
filtered_id AS(
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits) 
        AND rooms < (SELECT rooms_limit FROM limits) 
        AND balcony < (SELECT balcony_limit FROM limits) 
        AND ceiling_height < (SELECT ceiling_height_limit_h FROM limits) 
        AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)
    )
-- Выведем объявления без выбросов:
SELECT *
FROM real_estate.flats
WHERE id IN (SELECT * FROM filtered_id);
/* ============================================================
   ЗАДАЧА 1. Время активности объявлений
   ------------------------------------------------------------
   Цель:
   Определить, какие сегменты и характеристики недвижимости
   влияют на срок активности объявлений.

   Вопросы:
     1) Какие сегменты рынка имеют наиболее короткие
        или длинные сроки активности?
     2) Какие характеристики (площадь, цена м², комнаты,
        балконы и др.) влияют на время активности?
     3) Есть ли различия между рынком Санкт-Петербурга
        и Ленинградской области?
   ============================================================ */
-- Шаг 1. Считаем пороговые значения по перцентилям
-- для площади, комнат, балконов и высоты потолков,
-- чтобы дальше отфильтровать аномальные значения (выбросы).
WITH limits AS ( 
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Шаг 2. Отбираем объявления без выбросов (оставляем id и ключевые характеристики)   
filtered_data AS ( 
    SELECT 
        f.id AS ad_id,
        f.city_id,
        f.total_area,
        f.rooms,
        f.balcony,
        f.ceiling_height,
        a.days_exposition,
        a.last_price
    FROM real_estate.flats f
    JOIN real_estate.advertisement a ON f.id = a.id
    JOIN real_estate.type t ON f.type_id = t.type_id -- Используем связь через type_id из flats
    WHERE 
        t.type = 'город'                             -- Фильтрация только для городов
        AND f.total_area < (SELECT total_area_limit FROM limits)
        AND (f.rooms < (SELECT rooms_limit FROM limits) OR f.rooms IS NULL)
        AND (f.balcony < (SELECT balcony_limit FROM limits) OR f.balcony IS NULL)
        AND ((f.ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND f.ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR f.ceiling_height IS NULL)
),
-- Шаг 3. Присваиваем категории по городу/области и количеству дней активности объявлений    
categorized_data AS ( 
    SELECT
        fd.ad_id,
        CASE 
            WHEN fd.city_id = (SELECT city_id FROM real_estate.city WHERE city = 'Санкт-Петербург') THEN 'Санкт-Петербург'
            ELSE 'ЛенОбл'
        END AS region,
        CASE 
            WHEN fd.days_exposition BETWEEN 1 AND 30 THEN 'до месяца'
            WHEN fd.days_exposition BETWEEN 31 AND 90 THEN 'до трёх месяцев'
            WHEN fd.days_exposition BETWEEN 91 AND 180 THEN 'до полугода'
            ELSE 'более полугода'
        END AS activity_segment,
        fd.total_area,
        fd.rooms,
        fd.balcony,
        fd.ceiling_height,
        fd.last_price / NULLIF(fd.total_area, 0) AS price_per_sqm
    FROM filtered_data fd
),
-- Шаг 4. Рассчитаем основные показатели средняя цена за м² и площадь
-- медианные значения по комнатам, балконам и потолкам
--  и добавим количество объявлений
final_data AS ( 
    SELECT
        region,
        activity_segment,
        ROUND(AVG(price_per_sqm)::numeric, 2) AS avg_price_per_sqm,
        ROUND(AVG(total_area)::numeric, 2) AS avg_total_area,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rooms) AS median_rooms,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY balcony) AS median_balcony,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ceiling_height) AS median_ceiling_height,
        COUNT(*) AS ad_count --количество объявлений в каждой категории
    FROM categorized_data
    GROUP BY region, activity_segment
),
-- Шаг 5. Добавляем долю объявлений в каждой категории:
-- рассчитываем процент от общего числа объявлений в регионе   
percentages AS ( 
    SELECT
        fd.region,
        fd.activity_segment,
        fd.avg_price_per_sqm,
        fd.avg_total_area,
        fd.median_rooms,
        fd.median_balcony,
        fd.median_ceiling_height,
        fd.ad_count,
        ROUND(fd.ad_count * 100.0 / SUM(fd.ad_count) OVER (PARTITION BY fd.region), 2) AS ad_percentage --процент объявлений в каждой категории
    FROM final_data fd
)
-- Шаг 6. Показываем все рассчитанные показатели по регионам и сегментам активности
-- (средние и медианные значения, количество и доля объявлений).    
SELECT *
FROM percentages
ORDER BY region, activity_segment;
/* ============================================================
   ЗАДАЧА 2. Сезонность объявлений
   ------------------------------------------------------------
   Цель: выявить сезонные паттерны публикаций/снятий и влияние
         сезонности на цену м² и площадь.

   ВОПРОСЫ:
     1) В какие месяцы пик публикаций и снятий объявлений о продаже?
     2) Совпадают ли пики публикаций и продаж (снятий)?
     3) Как сезонность влияет на среднюю цену м² и площадь?
   ============================================================ */
-- Шаг 1. Определяем пороговые значения (перцентили) для признаков
-- чтобы отсеять аномальные значения (выбросы) по площади, комнатам,
-- балконам и высоте потолков, чтобы расчёты были корректнее.
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Шаг 2. Фильтруем объявления: исключаем квартиры с аномальными значениями
-- (слишком большая площадь/комнаты/балконы или нереальная высота потолков)    
filtered_flats AS (
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits)
        AND (rooms < (SELECT rooms_limit FROM limits) OR rooms IS NULL)
        AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
        AND ((ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR ceiling_height IS NULL)
),
-- Шаг 3. Формируем признаки для анализа:
-- дата публикации, дата снятия, месяц публикации/снятия,цена за квадратный метр, площадь квартиры.   
categorized_data AS (
    SELECT
        a.id AS ad_id,
        a.first_day_exposition,
        a.first_day_exposition + (a.days_exposition || ' days')::INTERVAL AS remove_date,  -- вычисляем дату снятия объявления
        EXTRACT(MONTH FROM a.first_day_exposition) AS publication_month,  -- месяц публикации
        EXTRACT(MONTH FROM (a.first_day_exposition + (a.days_exposition || ' days')::INTERVAL)) AS remove_month,  -- месяц снятия объявления
        a.last_price / f.total_area AS price_per_sqm, -- вычисляем стоимость квадратного метра
        f.total_area
    FROM real_estate.advertisement a
    JOIN real_estate.flats f ON a.id = f.id  -- фильтруем только по объявлениям без выбросов
    JOIN filtered_flats ff ON a.id = ff.id
    WHERE a.first_day_exposition IS NOT NULL AND a.days_exposition IS NOT NULL
),
-- Шаг 4. Считаем месячную активность рынка:
-- публикации и снятия объявлений, а также среднюю цену за м² и среднюю площадь по месяцам.    
monthly_activity AS (
    -- разделяем подсчёт опубликованных и снятых объявлений
    SELECT
        publication_month,
        COUNT(*) AS total_published,
        0 AS total_removed,
        AVG(price_per_sqm) AS avg_price_per_sqm,  -- средняя стоимость квадратного метра
        AVG(total_area) AS avg_total_area         -- средняя площадь
    FROM categorized_data
    GROUP BY publication_month
    UNION ALL
    SELECT
        remove_month,
        0 AS total_published,
        COUNT(*) AS total_removed,
        AVG(price_per_sqm) AS avg_price_per_sqm,  -- средняя стоимость квадратного метра
        AVG(total_area) AS avg_total_area         -- средняя площадь
    FROM categorized_data
    GROUP BY remove_month
),
-- Шаг 5. Итоговая агрегация:
-- сводим публикации, снятия и средние показатели (цена м², площадь) 
-- в помесячном разрезе для анализа сезонности и динамики рынка.    
monthly_activity_aggregated AS (  -- агрегируем данные по месяцам публикации и снятия
    SELECT
        publication_month,
        SUM(total_published) AS total_published,
        SUM(total_removed) AS total_removed,
        ROUND(AVG(avg_price_per_sqm)::numeric, 2) AS avg_price_per_sqm,
        ROUND(AVG(avg_total_area)::numeric, 2) AS avg_total_area
    FROM monthly_activity
    GROUP BY publication_month
)
SELECT 
    publication_month,
    total_published,
    total_removed,
    avg_price_per_sqm,
    avg_total_area
FROM monthly_activity_aggregated
ORDER BY publication_month;
/* ============================================================
   ЗАДАЧА 3. Анализ рынка недвижимости Ленинградской области
   ------------------------------------------------------------
   Цель: сравнить населённые пункты ЛО по активности, конверсии
         (доля снятых), цене м², площади и скорости продаж.

   ВОПРОСЫ:
     1) Где больше всего публикаций?
     2) Где самая высокая доля снятых объявлений (может указывать на высокую долю продаж)?
     3) Какова средняя цена м² и площадь по нас. пунктам? Вариация значений по этим метрикам?
     4) Где быстрее/медленнее продаётся недвижимость?
   ============================================================ */
-- Шаг 1. Определяем пороговые значения для признаков,
-- чтобы отсеять выбросы по площади, комнатам, балконам и потолкам.
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Шаг 2. Находим ID объявлений без выбросов
-- (фильтруем экстремальные значения по площади, комнатам,
--  балконам и высоте потолков)
filtered_id AS (
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits)
        AND (rooms < (SELECT rooms_limit FROM limits) OR rooms IS NULL)
        AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
        AND ((ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR ceiling_height IS NULL)
),
-- Шаг 3. Фильтруем только объявления без выбросов и исключаем Санкт-Петербург,
-- добавляем цену за м² и признак снятия объявления.
lenobl_flats AS (
    SELECT 
        f.id,
        c.city,
        f.total_area,
        a.last_price / NULLIF(f.total_area, 0) AS price_per_sqm, -- цена за квадратный метр
        a.days_exposition IS NOT NULL AS is_removed              -- признак снятия объявления
    FROM real_estate.flats f
    JOIN real_estate.advertisement a ON f.id = a.id
    JOIN real_estate.city c ON f.city_id = c.city_id
    JOIN real_estate.type t ON f.type_id = t.type_id
    WHERE f.id IN (SELECT id FROM filtered_id)        -- исключаем выбросы
      AND c.city != 'Санкт-Петербург'                 -- исключаем Санкт-Петербург
),
-- Шаг 4. Считаем ключевые метрики по населённым пунктам Ленобласти:
-- количество объявлений, доля снятых (продаж), средняя цена за м² и средняя площадь.
city_stats AS (
    SELECT 
        city,
        COUNT(*) AS total_ads,                                       -- общее количество объявлений
        AVG(CASE WHEN is_removed THEN 1 ELSE 0 END) AS removal_rate, -- доля снятых объявлений
        AVG(price_per_sqm) AS avg_price_per_sqm,                     -- средняя цена за квадратный метр
        AVG(total_area) AS avg_total_area                            -- средняя площадь квартиры
    FROM lenobl_flats
    GROUP BY city
)
-- Шаг 5. Выводим финальный результат:
-- ТОП-15 населённых пунктов Ленобласти с метриками: количество объявлений, доля снятых объявлений (%),
-- средняя цена за м² и средняя площадь.
SELECT 
    city,
    total_ads AS total_listings,
    ROUND(removal_rate * 100::numeric, 2) AS removal_rate_percent, -- доля снятых объявлений в процентах
    ROUND(avg_price_per_sqm::numeric, 2) AS avg_price_per_sqm,     -- средняя цена за квадратный метр
    ROUND(avg_total_area::numeric, 2) AS avg_total_area            -- среднея площадь
FROM city_stats
ORDER BY total_listings DESC
LIMIT 15;                                                          -- выбираем топ-15 населённых пунктов