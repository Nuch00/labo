#Necesita para correr en Google Cloud
# 256 GB de memoria RAM
# 256 GB de espacio en el disco local
#   8 vCPU


#limpio la memoria
rm( list=ls() )  #remove all objects
gc()             #garbage collection

require("data.table")
require("Rcpp")

require("ranger")
require("randomForest")  #solo se usa para imputar nulos

require("lightgbm")


#Parametros del script
PARAM  <- list()
PARAM$experimento <- "FINAL_V3_FE9000_2da"

PARAM$exp_input  <- "FINAL_V3_FE9000"

PARAM$lag1  <- F
PARAM$lag2  <- F
PARAM$lag6  <- F
PARAM$lag12  <- F

PARAM$Tendencias  <- F
PARAM$RandomForest  <- T          #No se puede poner en TRUE para la entrega oficial de la Tercera Competencia
PARAM$CanaritosAsesinos  <- F
# FIN Parametros del script

#------------------------------------------------------------------------------

options(error = function() { 
  traceback(20); 
  options(error = NULL); 
  stop("exiting after script error") 
})

#------------------------------------------------------------------------------
#se calculan para los 6 meses previos el minimo, maximo y tendencia calculada con cuadrados minimos
#la formula de calculo de la tendencia puede verse en https://stats.libretexts.org/Bookshelves/Introductory_Statistics/Book%3A_Introductory_Statistics_(Shafer_and_Zhang)/10%3A_Correlation_and_Regression/10.04%3A_The_Least_Squares_Regression_Line
#para la maxíma velocidad esta funcion esta escrita en lenguaje C, y no en la porqueria de R o Python

cppFunction('NumericVector fhistC(NumericVector pcolumna, IntegerVector pdesde ) 
{
  /* Aqui se cargan los valores para la regresion */
  double  x[100] ;
  double  y[100] ;

  int n = pcolumna.size();
  NumericVector out( 5*n );

  for(int i = 0; i < n; i++)
  {
    //lag
    if( pdesde[i]-1 < i )  out[ i + 4*n ]  =  pcolumna[i-1] ;
    else                   out[ i + 4*n ]  =  NA_REAL ;


    int  libre    = 0 ;
    int  xvalor   = 1 ;

    for( int j= pdesde[i]-1;  j<=i; j++ )
    {
       double a = pcolumna[j] ;

       if( !R_IsNA( a ) ) 
       {
          y[ libre ]= a ;
          x[ libre ]= xvalor ;
          libre++ ;
       }

       xvalor++ ;
    }

    /* Si hay al menos dos valores */
    if( libre > 1 )
    {
      double  xsum  = x[0] ;
      double  ysum  = y[0] ;
      double  xysum = xsum * ysum ;
      double  xxsum = xsum * xsum ;
      double  vmin  = y[0] ;
      double  vmax  = y[0] ;

      for( int h=1; h<libre; h++)
      { 
        xsum  += x[h] ;
        ysum  += y[h] ; 
        xysum += x[h]*y[h] ;
        xxsum += x[h]*x[h] ;

        if( y[h] < vmin )  vmin = y[h] ;
        if( y[h] > vmax )  vmax = y[h] ;
      }

      out[ i ]  =  (libre*xysum - xsum*ysum)/(libre*xxsum -xsum*xsum) ;
      out[ i + n ]    =  vmin ;
      out[ i + 2*n ]  =  vmax ;
      out[ i + 3*n ]  =  ysum / libre ;
    }
    else
    {
      out[ i       ]  =  NA_REAL ; 
      out[ i + n   ]  =  NA_REAL ;
      out[ i + 2*n ]  =  NA_REAL ;
      out[ i + 3*n ]  =  NA_REAL ;
    }
  }

  return  out;
}')

#------------------------------------------------------------------------------
#calcula la tendencia de las variables cols de los ultimos 6 meses
#la tendencia es la pendiente de la recta que ajusta por cuadrados minimos
#La funcionalidad de ratioavg es autoria de  Daiana Sparta,  UAustral  2021

TendenciaYmuchomas  <- function( dataset, cols, ventana=6, tendencia=TRUE, minimo=TRUE, maximo=TRUE, promedio=TRUE, 
                                 ratioavg=FALSE, ratiomax=FALSE)
{
  gc()
  #Esta es la cantidad de meses que utilizo para la historia
  ventana_regresion  <- ventana
  
  last  <- nrow( dataset )
  
  #creo el vector_desde que indica cada ventana
  #de esta forma se acelera el procesamiento ya que lo hago una sola vez
  vector_ids   <- dataset$numero_de_cliente
  
  vector_desde  <- seq( -ventana_regresion+2,  nrow(dataset)-ventana_regresion+1 )
  vector_desde[ 1:ventana_regresion ]  <-  1
  
  for( i in 2:last )  if( vector_ids[ i-1 ] !=  vector_ids[ i ] ) {  vector_desde[i] <-  i }
  for( i in 2:last )  if( vector_desde[i] < vector_desde[i-1] )  {  vector_desde[i] <-  vector_desde[i-1] }
  
  for(  campo  in   cols )
  {
    nueva_col     <- fhistC( dataset[ , get(campo) ], vector_desde ) 
    
    if(tendencia)  dataset[ , paste0( campo, "_tend", ventana) := nueva_col[ (0*last +1):(1*last) ]  ]
    if(minimo)     dataset[ , paste0( campo, "_min", ventana)  := nueva_col[ (1*last +1):(2*last) ]  ]
    if(maximo)     dataset[ , paste0( campo, "_max", ventana)  := nueva_col[ (2*last +1):(3*last) ]  ]
    if(promedio)   dataset[ , paste0( campo, "_avg", ventana)  := nueva_col[ (3*last +1):(4*last) ]  ]
    if(ratioavg)   dataset[ , paste0( campo, "_ratioavg", ventana)  := get(campo) /nueva_col[ (3*last +1):(4*last) ]  ]
    if(ratiomax)   dataset[ , paste0( campo, "_ratiomax", ventana)  := get(campo) /nueva_col[ (2*last +1):(3*last) ]  ]
  }
  
}
#------------------------------------------------------------------------------
#agrega al dataset nuevas variables {0,1} que provienen de las hojas de un Random Forest

AgregaVarRandomForest  <- function( num.trees, max.depth, min.node.size, mtry)
{
  gc()
  dataset[ , clase01:= ifelse( clase_ternaria=="CONTINUA", 0, 1 ) ]
  
  campos_buenos  <- setdiff( colnames(dataset), c("clase_ternaria" ) )
  
  dataset_rf  <- copy( dataset[ , campos_buenos, with=FALSE] )
  azar  <- runif( nrow(dataset_rf) )
  #dataset_rf[ , entrenamiento := as.integer( foto_mes>= 201901 &  foto_mes<= 202109 & !(foto_mes %in% c(202003,202004,202005,202006,202007,202008,202009,202010,202108,202109))  & ( clase01==1 | azar < 0.10 )) ]
  #meses= c('201901','201902','201903','201904','201905','201906','201907','201910','201911','201912','202001','202002','202003','202011','202012','202101','202102','202103','202104','202105','202106','202107')
  meses= c(201903, 201903, 201904, 201905, 201906, 201907, 201908, 201909, 201910, 201911, 201912, 202001, 202002, 202011, 202012, 202101, 202102, 202103, 202104, 202105, 202106)
  dataset_rf[ , entrenamiento := as.integer( (foto_mes %in% meses)  & ( clase01==1 | azar < 0.10 )) ]
  
  
  #imputo los nulos, ya que ranger no acepta nulos
  #Leo Breiman, ¿por que le temias a los nulos?
  dataset_rf  <- na.roughfix( dataset_rf )
  
  campos_buenos  <- setdiff( colnames(dataset_rf), c("clase_ternaria","entrenamiento" ) )
  modelo  <- ranger( formula= "clase01 ~ .",
                     data=  dataset_rf[ entrenamiento==1L, campos_buenos, with=FALSE  ] ,
                     classification= TRUE,
                     probability=   FALSE,
                     num.trees=     num.trees,
                     max.depth=     max.depth,
                     min.node.size= min.node.size,
                     mtry=          mtry
  )
  
  rfhojas  <- predict( object= modelo, 
                       data= dataset_rf[ , campos_buenos, with=FALSE ],
                       predict.all= TRUE,    #entrega la prediccion de cada arbol
                       type= "terminalNodes" #entrega el numero de NODO el arbol
  )
  
  for( arbol in 1:num.trees )
  {
    hojas_arbol  <- unique(  rfhojas$predictions[  , arbol  ] )
    
    for( pos in 1:length(hojas_arbol) )
    {
      nodo_id  <- hojas_arbol[ pos ]  #el numero de nodo de la hoja, estan salteados
      dataset[  ,  paste0( "rf_", sprintf( "%03d", arbol ), "_", sprintf( "%03d", nodo_id ) ) := 0L ]
      
      dataset[ which( rfhojas$predictions[ , arbol] == nodo_id ,  ), 
               paste0( "rf_", sprintf( "%03d", arbol ), "_", sprintf( "%03d", nodo_id ) ) := 1L ]
    }
  }
  
  rm( dataset_rf )
  dataset[ , clase01 := NULL ]
  
  gc()
}
#------------------------------------------------------------------------------
VPOS_CORTE  <- c()

fganancia_lgbm_meseta  <- function(probs, datos) 
{
  vlabels  <- get_field(datos, "label")
  vpesos   <- get_field(datos, "weight")
  
  tbl  <- as.data.table( list( "prob"=probs, "gan"= ifelse( vlabels==1 & vpesos > 1, 78000, -2000 ) ) )
  
  setorder( tbl, -prob )
  tbl[ , posicion := .I ]
  tbl[ , gan_acum :=  cumsum( gan ) ]
  setorder( tbl, -gan_acum )   #voy por la meseta
  
  gan  <- mean( tbl[ 1:500,  gan_acum] )  #meseta de tamaño 500
  
  pos_meseta  <- tbl[ 1:500,  median(posicion)]
  VPOS_CORTE  <<- c( VPOS_CORTE, pos_meseta )
  
  return( list( "name"= "ganancia", 
                "value"=  gan,
                "higher_better"= TRUE ) )
}
#------------------------------------------------------------------------------
#Elimina del dataset las variables que estan por debajo de la capa geologica de canaritos
#se llama varias veces, luego de agregar muchas variables nuevas, para ir reduciendo la cantidad de variables
# y así hacer lugar a nuevas variables importantes

GVEZ <- 1 

CanaritosAsesinos  <- function( canaritos_ratio=0.2, no_sacar=c() )
{
  gc()
  dataset[ , clase01:= ifelse( clase_ternaria=="CONTINUA", 0, 1 ) ]
  
  for( i  in 1:(ncol(dataset)*canaritos_ratio))  dataset[ , paste0("canarito", i ) :=  runif( nrow(dataset))]
  
  campos_buenos  <- setdiff( colnames(dataset), c("clase_ternaria","clase01", "foto_mes" ) )
  
  azar  <- runif( nrow(dataset) )
  dataset[ , entrenamiento := foto_mes>= 202101 &  foto_mes<= 202103  & ( clase01==1 | azar < 0.10 ) ]
  
  dtrain  <- lgb.Dataset( data=    data.matrix(  dataset[ entrenamiento==TRUE, campos_buenos, with=FALSE]),
                          label=   dataset[ entrenamiento==TRUE, clase01],
                          weight=  dataset[ entrenamiento==TRUE, ifelse(clase_ternaria=="BAJA+2", 1.0000001, 1.0)],
                          free_raw_data= FALSE
  )
  
  dvalid  <- lgb.Dataset( data=    data.matrix(  dataset[ foto_mes==202105, campos_buenos, with=FALSE]),
                          label=   dataset[ foto_mes==202105, clase01],
                          weight=  dataset[ foto_mes==202105, ifelse(clase_ternaria=="BAJA+2", 1.0000001, 1.0)],
                          free_raw_data= FALSE
  )
  
  
  param <- list( objective= "binary",
                 metric= "custom",
                 first_metric_only= TRUE,
                 boost_from_average= TRUE,
                 feature_pre_filter= FALSE,
                 verbosity= -100,
                 seed= 999983,
                 max_depth=  -1,         # -1 significa no limitar,  por ahora lo dejo fijo
                 min_gain_to_split= 0.0, #por ahora, lo dejo fijo
                 lambda_l1= 0.0,         #por ahora, lo dejo fijo
                 lambda_l2= 0.0,         #por ahora, lo dejo fijo
                 max_bin= 31,            #por ahora, lo dejo fijo
                 num_iterations= 9999,   #un numero muy grande, lo limita early_stopping_rounds
                 force_row_wise= TRUE,    #para que los alumnos no se atemoricen con tantos warning
                 learning_rate= 0.065, 
                 feature_fraction= 1.0,   #lo seteo en 1 para que las primeras variables del dataset no se vean opacadas
                 min_data_in_leaf= 260,
                 num_leaves= 60,
                 early_stopping_rounds= 200 )
  
  modelo  <- lgb.train( data= dtrain,
                        valids= list( valid= dvalid ),
                        eval= fganancia_lgbm_meseta,
                        param= param,
                        verbose= -100 )
  
  tb_importancia  <- lgb.importance( model= modelo )
  tb_importancia[  , pos := .I ]
  
  fwrite( tb_importancia, 
          file= paste0( "impo_", GVEZ ,".txt"),
          sep= "\t" )
  
  GVEZ  <<- GVEZ + 1
  
  umbral  <- tb_importancia[ Feature %like% "canarito", median(pos) + 2*sd(pos) ]  #Atencion corto en la mediana mas DOS desvios!!
  
  col_utiles  <- tb_importancia[ pos < umbral & !( Feature %like% "canarito"),  Feature ]
  col_utiles  <-  unique( c( col_utiles,  c("numero_de_cliente","foto_mes","clase_ternaria","mes") ) )
  col_inutiles  <- setdiff( colnames(dataset), col_utiles )
  
  ref = which(col_inutiles %in% no_sacar)
  if (length(ref)!=0){ 
    col_inutiles = col_inutiles[-ref]
  }
  
  dataset[  ,  (col_inutiles) := NULL ]
  
}
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
#Aqui empieza el programa

setwd( "~/buckets/b1/" )

#cargo el dataset donde voy a entrenar
#esta en la carpeta del exp_input y siempre se llama  dataset.csv.gz
dataset_input  <- paste0( "./exp/", PARAM$exp_input, "/dataset.csv.gz" )
dataset  <- fread( dataset_input )



#creo la carpeta donde va el experimento
dir.create( paste0( "./exp/", PARAM$experimento, "/"), showWarnings = FALSE )
setwd(paste0( "./exp/", PARAM$experimento, "/"))   #Establezco el Working Directory DEL EXPERIMENTO

#--------------------------------------
#estas son las columnas a las que se puede agregar lags o media moviles ( todas menos las obvias )
cols_lagueables  <- copy(  setdiff( colnames(dataset), c("numero_de_cliente", "foto_mes", "clase_ternaria")  ) )

#ordeno el dataset por <numero_de_cliente, foto_mes> para poder hacer lags
#  es MUY  importante esta linea
setorder( dataset, numero_de_cliente, foto_mes )


if( PARAM$lag1 )
{
  #creo los campos lags de orden 1
  dataset[ , paste0( cols_lagueables, "_lag1") := shift(.SD, 1, NA, "lag"), 
           by= numero_de_cliente, 
           .SDcols= cols_lagueables ]
  
  #agrego los delta lags de orden 1
  for( vcol in cols_lagueables )
  {
    dataset[ , paste0(vcol, "_delta1") := get(vcol)  - get(paste0( vcol, "_lag1"))  ]
  }
}


if( PARAM$lag2 )
{
  #creo los campos lags de orden 2
  dataset[ , paste0( cols_lagueables, "_lag2") := shift(.SD, 2, NA, "lag"), 
           by= numero_de_cliente, 
           .SDcols= cols_lagueables ]
  
  #agrego los delta lags de orden 2
  for( vcol in cols_lagueables )
  {
    dataset[ , paste0(vcol, "_delta2") := get(vcol)  - get(paste0( vcol, "_lag2"))  ]
  }
}


if( PARAM$lag6 )
{
  #creo los campos lags de orden 2
  dataset[ , paste0( cols_lagueables, "_lag6") := shift(.SD, 6, NA, "lag"), 
           by= numero_de_cliente, 
           .SDcols= cols_lagueables ]
  
  #agrego los delta lags de orden 2
  for( vcol in cols_lagueables )
  {
    dataset[ , paste0(vcol, "_delta6") := get(vcol)  - get(paste0( vcol, "_lag6"))  ]
  }
}

if( PARAM$lag12 )
{
  #creo los campos lags de orden 2
  dataset[ , paste0( cols_lagueables, "_lag12") := shift(.SD, 12, NA, "lag"), 
           by= numero_de_cliente, 
           .SDcols= cols_lagueables ]
  
  #agrego los delta lags de orden 2
  for( vcol in cols_lagueables )
  {
    dataset[ , paste0(vcol, "_delta12") := get(vcol)  - get(paste0( vcol, "_lag12"))  ]
  }
}



#--------------------------------------
#agrego las tendencias

#ordeno el dataset por <numero_de_cliente, foto_mes> para poder hacer lags
#  es MUY  importante esta linea
setorder( dataset, numero_de_cliente, foto_mes )

if( PARAM$Tendencias )
{
  TendenciaYmuchomas( dataset, 
                      cols= cols_lagueables,
                      ventana=   6,      # 6 meses de historia
                      tendencia= TRUE,
                      minimo=    T,
                      maximo=    T,
                      promedio=  TRUE,
                      ratioavg=  T,
                      ratiomax=  T  )
}

#------------------------------------------------------------------------------
#Agrego variables a partir de las hojas de un Random Forest

ref = which(startsWith(colnames(dataset),"rf"))
colnames(dataset)[ref] = paste0(colnames(dataset)[ref],'_1st') 

variables_buenas = c('cpayroll_trx_mas_mtarjeta_visa_consumo_rank','rf_036_061_1st',
                     'rf_018_056_1st','cpayroll_trx_pmax_mtarjeta_visa_consumo_rank',
                     'mcuentas_saldo_rank_pmax_mprestamos_personales_rank','cpayroll_trx_pmax_mpasivos_margen_rank',
                     'mcaja_ahorro_rank_pmax_mprestamos_personales_rank','cpayroll_trx_pmax_mprestamos_personales_rank',
                     'mcaja_ahorro_rank_mas_mprestamos_personales_rank','rf_029_058_1st',
                     'mprestamos_personales_rank_mas_mtarjeta_visa_consumo_rank','mcuentas_saldo_rank_pmax_cpayroll_trx',
                     'vm_status01_max6','rf_009_052_1st')



# 
# result <- expand.grid(a=variables_buenas,b=variables_buenas); 
# combinaciones = result[-which(result$a==result$b),]
# 
# combinaciones$a = as.character (combinaciones$a)
# combinaciones$b = as.character (combinaciones$b)
combinaciones =t(combn(variables_buenas,2))


for(i in 1:nrow(combinaciones)){
  v1=combinaciones[i,1]
  v2=combinaciones[i,2]
  
  dataset[,paste0(v1,'_mas_',v2):=get(v1)+get(v2)] 
  dataset[,paste0(v1,'_menos_',v2):=get(v1)-get(v2)] 
  dataset[,paste0(v1,'_div_',v2):=get(v1)/get(v2)] 
  dataset[,paste0(v2,'_div_',v1):=get(v2)/get(v1)] 
  dataset[,paste0(v1,'_mult_',v2):=get(v1)*get(v2)]   
  dataset[,paste0(v1,'_pmin_',v2):=pmin(get(v1),get(v2))]
  dataset[,paste0(v1,'_pmax_',v2):=pmax(get(v1),get(v2))]
  
  if(i %% 20 == 0){ CanaritosAsesinos( canaritos_ratio = 0.3, no_sacar = variables_buenas )
    print(i)
  }
}
#16:15


if( PARAM$RandomForest )
{
  AgregaVarRandomForest( num.trees = 40,
                         max.depth = 5,
                         min.node.size = 500,
                         mtry = 15 )
  
  gc()
}

#------------------------------------------------------------------------------
#Elimino las variables que no son tan importantes en el dataset
# with great power comes grest responsability

if( PARAM$CanaritosAsesinos )
{
  ncol( dataset )
  CanaritosAsesinos( canaritos_ratio = 0.3 )
  ncol( dataset )
}

#------------------------------------------------------------------------------










#------------------------------------------------------------------------------
#grabo el dataset
fwrite( dataset,
        "dataset.csv.gz",
        logical01= TRUE,
        sep= "," )
