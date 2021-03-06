
include("modulos/datasetImages.jl")
include("modulos/bondad.jl")

using Flux
using Flux.Losses
using Flux: onehotbatch, onecold
using JLD2, FileIO
using Statistics: mean
using Plots;
using Random;


imgH, imgW = 32, 32;

numColors = if true 3 else 2 end;

santa_imgs, _     = loadFolderImages("BBDD/papa_noel/santa", imgH, imgW);
not_santa_imgs, _ = loadFolderImages("BBDD/papa_noel/not-a-santa", imgH, imgW);

santa_imgs = convert(Array{Array{Float32,numColors},1}, santa_imgs);
not_santa_imgs = convert(Array{Array{Float32,numColors},1}, not_santa_imgs);

numPatrones = size(santa_imgs, 1)+size(not_santa_imgs, 1);
inDS = cat(santa_imgs, not_santa_imgs, dims=1);
outDS = cat(trues(size(santa_imgs,1)), falses(size(not_santa_imgs,1)), dims=1);

Random.seed!(1);
shuffle!(inDS);
Random.seed!(1);
shuffle!(outDS);

test_size = 32;

train_imgs   = inDS[1:(end-test_size)];
train_labels = outDS[1:(end-test_size)];
test_imgs    = inDS[(end-test_size):end];
test_labels  = outDS[(end-test_size):end];

# Tanto train_imgs como test_imgs son arrays de arrays bidimensionales (arrays de imagenes), es decir, son del tipo Array{Array{Float32,2},1}
#  Generalmente en Deep Learning los datos estan en tipo Float32 y no Float64, es decir, tienen menos precision
#  Esto se hace, entre otras cosas, porque las tarjetas gráficas (excepto las más recientes) suelen operar con este tipo de dato
#  Si se usa Float64 en lugar de Float32, el sistema irá mucho más lento porque tiene que hacer conversiones de Float64 a Float32

# Para procesar las imagenes con Deep Learning, hay que pasarlas una matriz en formato HWCN
#  Es decir, Height x Width x Channels x N
#  En el caso de esta base de datos
#   Height = 28
#   Width = 28
#   Channels = 1 -> son imagenes en escala de grises
#     Si fuesen en color, Channels = 3 (rojo, verde, azul)
# Esta conversion se puede hacer con la siguiente funcion:
function convertirArrayImagenesHWCN(imagenes)
    numPatrones = length(imagenes);
    nuevoArray = Array{Float32,4}(undef, imgH, imgW, numColors, numPatrones); # Importante que sea un array de Float32
    for i in 1:numPatrones
        @assert (size(imagenes[i])==(imgH,imgW,numColors)) "Las imagenes no tienen tamaño 28x28";
        nuevoArray[:,:,:,i] .= imagenes[i][:,:,:];
    end;
    return nuevoArray;
end;
train_imgs = convertirArrayImagenesHWCN(train_imgs);
test_imgs = convertirArrayImagenesHWCN(test_imgs);

println("Tamaño de la matriz de entrenamiento: ", size(train_imgs))
println("Tamaño de la matriz de test:          ", size(test_imgs))


# Cuidado: en esta base de datos las imagenes ya estan con valores entre 0 y 1
# En otro caso, habria que normalizarlas
println("Valores minimo y maximo de las entradas: (", minimum(train_imgs), ", ", maximum(train_imgs), ")");





# Cuando se tienen tantos patrones de entrenamiento (en este caso 60000),
#  generalmente no se entrena pasando todos los patrones y modificando el error
#  En su lugar, el conjunto de entrenamiento se divide en subconjuntos (batches)
#  y se van aplicando uno a uno

# Hacemos los indices para las particiones
# Cuantos patrones va a tener cada particion
batch_size = 128;
# Creamos los indices: partimos el vector 1:N en grupos de batch_size
gruposIndicesBatch = Iterators.partition(1:size(train_imgs,4), batch_size);
println("He creado ", length(gruposIndicesBatch), " grupos de indices para distribuir los patrones en batches");


# Creamos el conjunto de entrenamiento: va a ser un vector de tuplas. Cada tupla va a tener
#  Como primer elemento, las imagenes de ese batch
#     train_imgs[:,:,:,indicesBatch]
#  Como segundo elemento, las salidas deseadas (en booleano, codificadas con one-hot-encoding) de esas imagenes
#     Para conseguir estas salidas deseadas, se hace una llamada a la funcion onehotbatch, que realiza un one-hot-encoding de las etiquetas que se le pasen como parametros
#     onehotbatch(train_labels[indicesBatch], labels)
#  Por tanto, cada batch será un par dado por
#     (train_imgs[:,:,:,indicesBatch], onehotbatch(train_labels[indicesBatch], labels))
# Sólo resta iterar por cada batch para construir el vector de batches
train_set = [ (train_imgs[:,:,:,indicesBatch], train_labels[indicesBatch]) for indicesBatch in gruposIndicesBatch];

# Creamos un batch similar, pero con todas las imagenes de test
test_set = (test_imgs, test_labels);


# Hago esto simplemente para liberar memoria, las variables train_imgs y test_imgs ocupan mucho y ya no las vamos a usar
train_imgs = nothing;
test_imgs = nothing;
GC.gc(); # Pasar el recolector de basura



funcionTransferenciaCapasConvolucionales = relu;

# Definimos la red con la funcion Chain, que concatena distintas capas
ann = Chain(

    # Primera capa: convolucion, que opera sobre una imagen 28x28
    # Argumentos:
    #  (3, 3): Tamaño del filtro de convolucion
    #  1=>16:
    #   1 canal de entrada: una imagen (matriz) de entradas
    #      En este caso, hay un canal de entrada porque es una imagen en escala de grises
    #      Si fuese, por ejemplo, una imagen en RGB, serian 3 canales de entrada
    #   16 canales de salida: se generan 16 filtros
    #  Es decir, se generan 16 imagenes a partir de la imagen original con filtros 3x3
    # Entradas a esta capa: matriz 4D de dimension 28 x 28 x 1canal    x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension 28 x 28 x 16canales x <numPatrones>
    Conv((3, 3), numColors=>32*numColors, pad=(1,1), funcionTransferenciaCapasConvolucionales),

    # Capa maxpool: es una funcion
    # Divide el tamaño en 2 en el eje x y en el eje y: Pasa imagenes 28x28 a 14x14
    # Entradas a esta capa: matriz 4D de dimension 28 x 28 x 16canales x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension 14 x 14 x 16canales x <numPatrones>
    MaxPool((2,2)),

    # Tercera capa: segunda convolucion: Le llegan 16 imagenes de tamaño 14x14
    #  16=>32:
    #   16 canales de entrada: 16 imagenes (matrices) de entradas
    #   32 canales de salida: se generan 32 filtros (cada uno toma entradas de 16 imagenes)
    #  Es decir, se generan 32 imagenes a partir de las 16 imagenes de entrada con filtros 3x3
    # Entradas a esta capa: matriz 4D de dimension 14 x 14 x 16canales x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension 14 x 14 x 32canales x <numPatrones>
    Conv((3, 3), numColors*32=>numColors*64, pad=(1,1), funcionTransferenciaCapasConvolucionales),

    # Capa maxpool: es una funcion
    # Divide el tamaño en 2 en el eje x y en el eje y: Pasa imagenes 14x14 a 7x7
    # Entradas a esta capa: matriz 4D de dimension 14 x 14 x 32canales x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension  7 x  7 x 32canales x <numPatrones>
    MaxPool((2,2)),

    # Cambia el tamaño del tensot 3D en uno 2D
    #  Pasa matrices H x W x C x N a matrices H*W*C x N
    #  Es decir, cada patron de tamaño 3 x 3 x 32 lo convierte en un array de longitud 3*3*32
    # Entradas a esta capa: matriz 4D de dimension 3 x 3 x 32canales x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension 288 x <numPatrones>
    x -> reshape(x, :, size(x, 4)),

    # Capa totalmente conectada
    #  Como una capa oculta de un perceptron multicapa "clasico"
    #  Parametros: numero de entradas (288) y numero de salidas (10)
    #   Se toman 10 salidas porque tenemos 10 clases (numeros de 0 a 9)
    # Entradas a esta capa: matriz 4D de dimension 288 x <numPatrones>
    # Salidas de esta capa: matriz 4D de dimension  10 x <numPatrones>
    Dense(12288, 1, σ),
)



# Vamos a probar la RNA capa por capa y poner algunos datos de cada capa
# Usaremos como entrada varios patrones de un batch
numBatchCoger = 1; numImagenEnEseBatch = [12, 6];
# Para coger esos patrones de ese batch:
#  train_set es un array de tuplas (una tupla por batch), donde, en cada tupla, el primer elemento son las entradas y el segundo las salidas deseadas
#  Por tanto:
#   train_set[numBatchCoger] -> La tupla del batch seleccionado
#   train_set[numBatchCoger][1] -> El primer elemento de esa tupla, es decir, las entradas de ese batch
#   train_set[numBatchCoger][1][:,:,:,numImagenEnEseBatch] -> Los patrones seleccionados de las entradas de ese batch
entradaCapa = train_set[numBatchCoger][1][:,:,:,numImagenEnEseBatch];
numCapas = length(params(ann));
println("La RNA tiene ", numCapas, " capas:");
for numCapa in 1:numCapas
    println("   Capa ", numCapa, ": ", ann[numCapa]);
    # Le pasamos la entrada a esta capa
    global entradaCapa # Esta linea es necesaria porque la variable entradaCapa es global y se modifica en este bucle
    capa = ann[numCapa];
    salidaCapa = capa(entradaCapa);
    println("      La salida de esta capa tiene dimension ", size(salidaCapa));
    entradaCapa = salidaCapa;
end

# Sin embargo, para aplicar un patron no hace falta hacer todo eso.
#  Se puede aplicar patrones a la RNA simplemente haciendo, por ejemplo
ann(train_set[numBatchCoger][1][:,:,:,numImagenEnEseBatch]);




# Definimos la funcion de loss de forma similar a las prácticas de la asignatura
loss(x, y) = (size(y,1) == 1) ? Losses.binarycrossentropy(ann(x),y) : Losses.crossentropy(ann(x),y);
# Para calcular la precisión, hacemos un "one cold encoding" de las salidas del modelo y de las salidas deseadas, y comparamos ambos vectores
accuracy(batch) = accuracy(batch[2], ann(batch[1])[:]);
# Un batch es una tupla (entradas, salidasDeseadas), asi que batch[1] son las entradas, y batch[2] son las salidas deseadas


# Mostramos la precision antes de comenzar el entrenamiento:
#  train_set es un array de batches
#  accuracy recibe como parametro un batch
#  accuracy.(train_set) hace un broadcast de la funcion accuracy a todos los elementos del array train_set
#   y devuelve un array con los resultados
#  Por tanto, mean(accuracy.(train_set)) calcula la precision promedia
#   (no es totalmente preciso, porque el ultimo batch tiene menos elementos, pero es una diferencia baja)
println("Ciclo 0: Precision en el conjunto de entrenamiento: ", 100*mean(accuracy.(train_set)), " %");


# Optimizador que se usa: ADAM, con esta tasa de aprendizaje:
opt = ADAM(0.001);


println("Comenzando entrenamiento...")
mejorPrecision = -Inf;
criterioFin = false;
numCiclo = 0;
numCicloUltimaMejora = 0;
mejorModelo = nothing;
errores = [];

while (!criterioFin)

    # Hay que declarar las variables globales que van a ser modificadas en el interior del bucle
    global numCicloUltimaMejora, numCiclo, mejorPrecision, mejorModelo, criterioFin;

    # Se entrena un ciclo
    Flux.train!(loss, params(ann), train_set, opt);

    push!(errores, loss(train_set[1][1][:,:,:,:], train_set[1][2][:]));

    numCiclo += 1;

    # Se calcula la precision en el conjunto de entrenamiento:
    precisionEntrenamiento = mean(accuracy.(train_set));
    println("Ciclo ", numCiclo, ": Precision en el conjunto de entrenamiento: ", 100*precisionEntrenamiento, " %");

    # Si se mejora la precision en el conjunto de entrenamiento, se calcula la de test y se guarda el modelo
    if (precisionEntrenamiento >= mejorPrecision)
        mejorPrecision = precisionEntrenamiento;
        precisionTest = accuracy(test_set);
        println("   Mejora en el conjunto de entrenamiento -> Precision en el conjunto de test: ", 100*precisionTest, " %");
        mejorModelo = deepcopy(ann);
        numCicloUltimaMejora = numCiclo;
    end

    # Si no se ha mejorado en 5 ciclos, se baja la tasa de aprendizaje
    if (numCiclo - numCicloUltimaMejora >= 5) && (opt.eta > 1e-6)
        opt.eta /= 10.0
        println("   No se ha mejorado en 5 ciclos, se baja la tasa de aprendizaje a ", opt.eta);
        numCicloUltimaMejora = numCiclo;
    end

    # Criterios de parada:

    # Si la precision en entrenamiento es lo suficientemente buena, se para el entrenamiento
    if (precisionEntrenamiento >= 0.999)
        println("   Se para el entenamiento por haber llegado a una precision de 99.9%")
        criterioFin = true;
    end

    # Si no se mejora la precision en el conjunto de entrenamiento durante 10 ciclos, se para el entrenamiento
    if (numCiclo - numCicloUltimaMejora >= 10)
        println("   Se para el entrenamiento por no haber mejorado la precision en el conjunto de entrenamiento durante 10 ciclos")
        criterioFin = true;
    end
end

plot(errores)

