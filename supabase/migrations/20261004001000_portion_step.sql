-- 먹은 양을 0.1인분 단위(0.1~3.0)로 조정한다(D60). 앱 P7 의 밥·국·반찬 공통 스테퍼가 배수를 portion_multiplier 로 보낸다.
-- 전에는 0.25~2.0 이라 0.1인분·2.5인분·3인분을 저장할 수 없었다. 자료형 numeric(3,2) 는 그대로.
alter table meal_items drop constraint meal_items_portion_multiplier_check;
alter table meal_items add constraint meal_items_portion_multiplier_check check (portion_multiplier between 0.1 and 3.0);
