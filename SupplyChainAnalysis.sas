
/* Combining the dasets */
proc sort data=ABC.COMBINE_DATA out=work._tmpsort1_;
	by ProductName;
run;

proc sort data=ABC.FULFILLMENT out=work._tmpsort2_;
	by ProductName;
run;

data ABC.ORDSHIP_ANALYSIS;
	merge _tmpsort1_ (keep=OrderID OrderItemID YearMonth OrderYear OrderMonth 
		OrderDay OrderTime OrderQuantity ProductDepartment ProductCategory 
		ProductName CustomerID CustomerMarket CustomerRegion CustomerCountry 
		WarehouseCountry ShipmentYear ShipmentMonth ShipmentDay ShipmentMode 
		ShipmentDaysScheduled GrossSales Discount Profit OrderDateTime ShipDate 
		WarehouseInventory InventoryCostPerUnit ProductName) 
		_tmpsort2_(keep=dock_stock_days ProductName);
	by ProductName;
run;

proc delete data=work._tmpsort1_ work._tmpsort2_;
run;

/*Delete items that were not associated with any order. This was out of scope for analysis*/
proc sql;
  DELETE FROM ABC.ORDSHIP_ANALYSIS
  WHERE warehouseinventory=0
  AND ORDERID IS NULL;

quit;

/* Create additional metric columns for analysis*/
data abc.ordship_analysis;
    set abc.ordship_analysis;
    OrderProcessingTime = int((shipdate - orderdatetime)/ 86400) ;
    TotalInvStorageCost = (WarehouseInventory * InventoryCostPerUnit);
    InventoryToSalesDelta = ((WarehouseInventory) - OrderQuantity); 
      
          IF InventoryToSalesDelta > 0 THEN
          OverStock = 'Yes'; 
          ELSE 
          OverStock = 'No';
   
run;

/* Standardize data*/
ods noproctitle;

proc stdize data=ABC.ORDSHIP_ANALYSIS method=std nomiss 
		out=ABC.STANDARDIZED_DATA oprefix sprefix=Standardized_;
	var ShipmentDaysScheduled WarehouseInventory dock_stock_days 
		OrderProcessingTime TotalInvStorageCost OrderQuantity;
run;

/*Create variable nventory_management_score*/
data abc.ordship_analysis;
	set abc.standardized_data;
	inventory_management_score = mean(standardized_shipmentdaysschedu, standardized_warehouse_inventory, standardized_dock_stock_days, 
	standardized_orderprocessingtime, standardized_totalinvstoragecost);
run;

/* Create a binary grouping to group the inventory score.
Since the score was imbalanced, the mean had to be divided by 2 to try a score of 1*/
data abc.ordship_analysis;
	set abc.ordship_analysis;
	if inventory_management_score > mean(inventory_management_score)/2 then score_group = 1; /* good */
	else score_group = 0; /* poor */
run;

/* Products with high inventory levels compared to their sales performance
Calculate total sales and inventory for each product */
proc sql;
    create table ABC.overstock_issues as
    select ProductName, OrderYear,OrderMonth,
           sum(OrderQuantity) as TotalOrderQuantity,
           sum(WarehouseInventory) as TotalInventory,
           sum(GrossSales) as TotalSales,
           avg(score_group) as AvgInventoryPracticeScore
    from abc.ordship_analysis
    group by ProductName,OrderYear,OrderMonth;
quit;

/* Identify overstock issues 
Identifies products with inventory levels significantly higher than their order quantities 
(here, I used a threshold of 1.5 times the order quantity, but you can adjust this as needed).*/
data abc.overstock_issues;
    set abc.overstock_issues;
    if TotalInventory > (TotalOrderQuantity*1.5) then OverstockFlag = 1;
    else OverstockFlag = 0;
run;

/* Display products with overstock issues */
proc print data=abc.overstock_issues;
    where OverstockFlag = 1;
run;

/*Modelling and forecasting - ARIMAX*/

ods noproctitle;
ods graphics / imagemap=on;

proc sort data=ABC.ORDSHIP_ANALYSIS out=Work.preProcessedData;
	by OrderYear;
run;

proc arima data=Work.preProcessedData plots
    (only)=(series(corr crosscorr) residual(corr normal) 
		forecast(forecastonly));
	identify var=GrossSales crosscorr=(inventory_management_score);
	estimate q=(1) input=(inventory_management_score) method=ML;
	forecast lead=12 back=0 alpha=0.05 id=OrderYear interval=day;
	outlier;
	run;
quit;

proc delete data=Work.preProcessedData;
run;

/* Decision tree for overstock levels 
decision trees to analyze the impact of inventory management practices on gross sales*/
proc hpsplit data=abc.ordship_analysis;
    class overstock;
    model overstock = GrossSales;
run;

/* Decision tree for overstock levels 
decision trees to analyze the impact of inventory management practices on overstock levels*/
proc hpsplit data=abc.ordship_analysis;
    class overstock;
    model overstock = inventory_management_score;
run;